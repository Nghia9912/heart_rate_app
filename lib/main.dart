import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: HRVProfessionalPage(),
  ));
}

enum AppState { idle, measuring, result }

class HRVProfessionalPage extends StatefulWidget {
  const HRVProfessionalPage({super.key});
  @override
  State<HRVProfessionalPage> createState() => _HRVProfessionalPageState();
}

class _HRVProfessionalPageState extends State<HRVProfessionalPage> with WidgetsBindingObserver {
  // --- HARDWARE ---
  CameraController? _controller;
  bool _isCameraInitialized = false;

  // --- STATE ---
  AppState _appState = AppState.idle;
  bool _isScanInProgress = false;
  Timer? _timer;
  int _elapsedSeconds = 0;
  final int _measurementDuration = 60;
  bool _isFingerDetected = false;

  // --- DATA ---
  final List<double> _chartData = [];
  final List<double> _rrIntervalsHighPrecision = [];
  final List<int> _bpmBuffer = [];
  int _displayBpm = 0;

  // --- DSP VARIABLES ---
  final List<double> _rawSignalBuffer = [];
  final List<double> _filteredSignal = [];
  final int _bufferSize = 256;
  final List<double> _maBuffer = [];

  // Timing & Peaks
  final Stopwatch _measurementStopwatch = Stopwatch();
  double? _lastPeakTimestamp;
  int _framesSinceLastPeak = 0;
  final int _refractionPeriod = 12;
  double _signalQuality = 0.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();
    _initializeCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WakelockPlus.disable();
    _timer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      _controller?.setFlashMode(FlashMode.off);
      _controller?.dispose();
      _controller = null;

      if (mounted) {
        setState(() {
          _isCameraInitialized = false;
          _isFingerDetected = false;
        });
      }
    } else if (state == AppLifecycleState.resumed) {
      if (_controller == null || !_controller!.value.isInitialized) {
        _initializeCamera();
      }
    }
  }

  // --- LOGIC: ORIGINAL SENSOR TRAP (Best Accuracy) ---
  Future<void> _initializeCamera() async {
    await Permission.camera.request();
    final cameras = await availableCameras();
    CameraDescription selectedCamera = cameras.firstWhere(
          (cam) => cam.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    if (_controller != null) await _controller!.dispose();

    _controller = CameraController(
      selectedCamera,
      ResolutionPreset.low, // Keep low res for performance
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    try {
      await _controller!.initialize();

      // 1. Flash OFF
      await _controller!.setFlashMode(FlashMode.off);

      // 2. Auto Exposure + Max Offset
      await _controller!.setExposureMode(ExposureMode.auto);
      try {
        double maxExposure = await _controller!.getMaxExposureOffset();
        await _controller!.setExposureOffset(maxExposure);
      } catch (e) {
        debugPrint("Exposure Error: $e");
      }

      // 3. Wait for ISO spike
      await Future.delayed(const Duration(milliseconds: 50));

      // 4. Lock Settings
      await _controller!.setExposureMode(ExposureMode.locked);
      await _controller!.setFocusMode(FocusMode.locked);

      // 5. Flash ON -> Max Penetration
      await _controller!.setFlashMode(FlashMode.torch);

      _controller!.startImageStream(_processImage);
      if (mounted) setState(() => _isCameraInitialized = true);
    } catch (e) {
      debugPrint("Camera Error: $e");
    }
  }

  double _movingAverage(double newValue, List<double> buffer, int windowSize) {
    buffer.add(newValue);
    if (buffer.length > windowSize) buffer.removeAt(0);
    return buffer.reduce((a, b) => a + b) / buffer.length;
  }

  // --- LOGIC: ORIGINAL DSP LOOP (No Lag) ---
  void _processImage(CameraImage image) {
    if (_isScanInProgress) return;
    _isScanInProgress = true;

    final int width = image.width;
    final int height = image.height;
    final int yStride = image.planes[0].bytesPerRow;
    int centerX = width ~/ 2;
    int centerY = height ~/ 2;
    int range = 40;

    int sum = 0;
    int count = 0;
    double sumSquaredDiff = 0.0;
    List<int> pixelSamples = [];

    for (int y = centerY - range; y < centerY + range; y += 2) {
      for (int x = centerX - range; x < centerX + range; x += 2) {
        if (y >= 0 && y < height && x >= 0 && x < width) {
          int pixel = image.planes[0].bytes[y * yStride + x];
          sum += pixel;
          pixelSamples.add(pixel);
          count++;
        }
      }
    }

    if (count == 0) { _isScanInProgress = false; return; }
    double rawAvg = sum / count;

    for (int p in pixelSamples) {
      double diff = p - rawAvg;
      sumSquaredDiff += diff * diff;
    }
    double stdDev = math.sqrt(sumSquaredDiff / count);

    bool isFingerPresentNow = ((rawAvg > 30 && rawAvg < 255) && stdDev < 30);

    if (_isFingerDetected != isFingerPresentNow) {
      Future.microtask(() { if (mounted) setState(() => _isFingerDetected = isFingerPresentNow); });
    }

    if (!isFingerPresentNow) {
      _resetSignalBuffers();
      _isScanInProgress = false;
      return;
    }

    _rawSignalBuffer.add(rawAvg);
    if (_rawSignalBuffer.length > _bufferSize) _rawSignalBuffer.removeAt(0);
    if (_rawSignalBuffer.length < 5) { _isScanInProgress = false; return; }

    double smoothed = _movingAverage(rawAvg, _maBuffer, 5);

    double baseline = smoothed;
    if (_rawSignalBuffer.length > 30) {
      baseline = _rawSignalBuffer.sublist(_rawSignalBuffer.length - 30).reduce((a, b) => a + b) / 30;
    }
    double filtered = smoothed - baseline;

    _filteredSignal.add(filtered);
    if (_filteredSignal.length > _bufferSize) _filteredSignal.removeAt(0);

    // SQI
    if (_filteredSignal.length > 60) {
      List<double> recent = _filteredSignal.sublist(_filteredSignal.length - 60);
      double maxVal = recent.reduce((a, b) => a > b ? a : b);
      double minVal = recent.reduce((a, b) => a < b ? a : b);
      _signalQuality = math.min(1.0, (maxVal - minVal) / 5.0);
    }

    // Peak Detection & Interpolation
    if (_filteredSignal.length >= 3) {
      double prev = _filteredSignal[_filteredSignal.length - 3];
      double curr = _filteredSignal[_filteredSignal.length - 2];
      double next = _filteredSignal[_filteredSignal.length - 1];

      List<double> recent = _filteredSignal.length > 60 ? _filteredSignal.sublist(_filteredSignal.length - 60) : _filteredSignal;
      double minV = recent.reduce(math.min);
      double maxV = recent.reduce(math.max);
      double threshold = minV + (maxV - minV) * 0.5;

      _framesSinceLastPeak++;

      if (curr > prev && curr > next && curr > threshold && _framesSinceLastPeak > _refractionPeriod) {

        double denominator = 2 * (prev - 2 * curr + next);
        double delta = 0.0;
        if (denominator != 0) {
          delta = (prev - next) / denominator;
        }

        double currentFrameTimeMs = _measurementStopwatch.elapsedMicroseconds / 1000.0;
        double frameDuration = 33.33;

        double exactPeakTime = currentFrameTimeMs - frameDuration + (delta * frameDuration);

        if (_lastPeakTimestamp != null) {
          double rrInterval = exactPeakTime - _lastPeakTimestamp!;

          if (rrInterval >= 375 && rrInterval <= 1500) {

            bool isValid = true;
            if (_bpmBuffer.isNotEmpty) {
              double avgBpm = _bpmBuffer.reduce((a, b) => a + b) / _bpmBuffer.length;
              double instantBpm = 60000 / rrInterval;
              if ((instantBpm - avgBpm).abs() > 20) isValid = false;
            }

            if (isValid || _bpmBuffer.isEmpty) {
              if (_appState == AppState.measuring) {
                _rrIntervalsHighPrecision.add(rrInterval);
              }

              int instantBpm = (60000 / rrInterval).round();
              _bpmBuffer.add(instantBpm);
              if (_bpmBuffer.length > 5) _bpmBuffer.removeAt(0);

              int displayVal = (_bpmBuffer.reduce((a, b) => a + b) / _bpmBuffer.length).round();
              Future.microtask(() { if (mounted) setState(() => _displayBpm = displayVal); });

              _framesSinceLastPeak = 0;
              _lastPeakTimestamp = exactPeakTime;
            }
          } else if (rrInterval > 2000) {
            _lastPeakTimestamp = exactPeakTime;
            _bpmBuffer.clear();
          }
        } else {
          _lastPeakTimestamp = exactPeakTime;
        }
      }
    }

    // Chart Update
    Future.microtask(() {
      if (mounted) {
        setState(() {
          _chartData.add(filtered);
          if (_chartData.length > 150) _chartData.removeAt(0);
        });
      }
    });
    _isScanInProgress = false;
  }

  void _resetSignalBuffers() {
    _rawSignalBuffer.clear();
    _filteredSignal.clear();
    _bpmBuffer.clear();
    _framesSinceLastPeak = 0;
    _maBuffer.clear();
  }

  Map<String, double> _calculateHRVMetrics() {
    if (_rrIntervalsHighPrecision.length < 20) {
      return {'sdnn': 0, 'rmssd': 0, 'pnn50': 0, 'mxdmn': 0, 'amo50': 0};
    }

    List<double> sorted = List.from(_rrIntervalsHighPrecision)..sort();
    int q1Index = sorted.length ~/ 4;
    int q3Index = (sorted.length * 3) ~/ 4;
    double q1 = sorted[q1Index];
    double q3 = sorted[q3Index];
    double iqr = q3 - q1;
    double lowerBound = q1 - 1.5 * iqr;
    double upperBound = q3 + 1.5 * iqr;

    List<double> cleanedRR = _rrIntervalsHighPrecision.where((rr) => rr >= lowerBound && rr <= upperBound).toList();
    if (cleanedRR.length < 10) cleanedRR = _rrIntervalsHighPrecision;

    double mean = cleanedRR.reduce((a, b) => a + b) / cleanedRR.length;
    double variance = 0;
    for (var rr in cleanedRR) {
      variance += (rr - mean) * (rr - mean);
    }
    double sdnn = math.sqrt(variance / cleanedRR.length);

    double sumSquaredDiff = 0;
    for (int i = 1; i < cleanedRR.length; i++) {
      double diff = cleanedRR[i] - cleanedRR[i - 1];
      sumSquaredDiff += diff * diff;
    }
    double rmssd = math.sqrt(sumSquaredDiff / (cleanedRR.length - 1));

    int count50 = 0;
    for (int i = 1; i < cleanedRR.length; i++) {
      if ((cleanedRR[i] - cleanedRR[i - 1]).abs() > 50) {
        count50++;
      }
    }
    double pnn50 = (count50 / (cleanedRR.length - 1)) * 100;

    double maxRR = cleanedRR.reduce(math.max);
    double minRR = cleanedRR.reduce(math.min);
    double mxdmn = maxRR - minRR;

    Map<int, int> histogram = {};
    for (var rr in cleanedRR) {
      int bucket = (rr / 50).round() * 50;
      histogram[bucket] = (histogram[bucket] ?? 0) + 1;
    }
    int maxCount = histogram.values.isEmpty ? 0 : histogram.values.reduce(math.max);
    double amo50 = (maxCount / cleanedRR.length) * 100;

    return {
      'sdnn': sdnn,
      'rmssd': rmssd,
      'pnn50': pnn50,
      'mxdmn': mxdmn,
      'amo50': amo50,
    };
  }

  void _startMeasurement() {
    _timer?.cancel();
    _measurementStopwatch.reset();
    _measurementStopwatch.start();

    setState(() {
      _appState = AppState.measuring;
      _rrIntervalsHighPrecision.clear();
      _bpmBuffer.clear();
      _elapsedSeconds = 0;
      _displayBpm = 0;
      _lastPeakTimestamp = null;
    });

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) { timer.cancel(); return; }
      if (_isFingerDetected) {
        setState(() {
          _elapsedSeconds++;
        });
        if (_elapsedSeconds >= _measurementDuration) {
          _finishMeasurement();
        }
      }
    });
  }

  void _finishMeasurement() {
    _timer?.cancel();
    _measurementStopwatch.stop();
    setState(() => _appState = AppState.result);
  }

  void _resetApp() {
    _timer?.cancel();
    _measurementStopwatch.stop();
    _measurementStopwatch.reset();
    setState(() {
      _appState = AppState.idle;
      _elapsedSeconds = 0;
      _rrIntervalsHighPrecision.clear();
      _chartData.clear();
      _displayBpm = 0;
      _bpmBuffer.clear();
      _isFingerDetected = false;
      _resetSignalBuffers();
    });
  }

  Future<void> _handleBackPress() async {
    if (_appState == AppState.measuring) {
      bool shouldStop = await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: Colors.grey[800],
          title: const Text("Stop Measurement?", style: TextStyle(color: Colors.white)),
          content: const Text("Current data will be lost.", style: TextStyle(color: Colors.white70)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text("Continue", style: TextStyle(color: Colors.white)),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text("Stop", style: TextStyle(color: Colors.redAccent)),
            ),
          ],
        ),
      ) ?? false;
      if (shouldStop) _resetApp();
    } else if (_appState == AppState.result) {
      _resetApp();
    } else {
      SystemNavigator.pop();
    }
  }

  void _copyResults() {
    var metrics = _calculateHRVMetrics();
    String data = """
HRV REPORT (Clinical Precision)
Date: ${DateTime.now().toString()}
Avg BPM: $_displayBpm
Total Beats: ${_rrIntervalsHighPrecision.length}
-- Time Domain --
SDNN: ${metrics['sdnn']!.toStringAsFixed(1)} ms
RMSSD: ${metrics['rmssd']!.toStringAsFixed(1)} ms
pNN50: ${metrics['pnn50']!.toStringAsFixed(1)} %
-- Baevsky Stress Index --
MxDMn: ${metrics['mxdmn']!.toStringAsFixed(0)} ms
AMo50: ${metrics['amo50']!.toStringAsFixed(1)} %
    """;
    Clipboard.setData(ClipboardData(text: data));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Results copied to clipboard!")),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) { if (!didPop) _handleBackPress(); },
      child: Scaffold(
        backgroundColor: const Color(0xFF0a0a0a),
        body: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              Expanded(
                child: Center(
                  child: _appState == AppState.idle
                      ? _buildIdleView()
                      : _appState == AppState.measuring
                      ? _buildMeasuringView()
                      : _buildResultView(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- UI: PRO INTERFACE WITH GRADIENTS (No Back Button) ---
  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.black, Colors.grey[900]!],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              // 1. Logo (No Back Button here)
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.all(5),
                child: Image.asset(
                  'assets/images/logo.png',
                  fit: BoxFit.contain,
                ),
              ),
              const SizedBox(width: 12),
              // 2. App Name
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "HRV MONITOR",
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                      letterSpacing: 1.2,
                    ),
                  ),
                  Text(
                    "Professional Edition",
                    style: TextStyle(
                      color: Colors.grey,
                      fontSize: 11,
                      fontWeight: FontWeight.w300,
                    ),
                  ),
                ],
              ),
            ],
          ),
          // 3. Camera Preview with Border Animation
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: _isFingerDetected ? Colors.greenAccent : Colors.redAccent,
                width: 3,
              ),
              boxShadow: [
                BoxShadow(
                  color: (_isFingerDetected ? Colors.greenAccent : Colors.redAccent).withOpacity(0.5),
                  blurRadius: 10,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: ClipOval(
              child: _isCameraInitialized
                  ? CameraPreview(_controller!)
                  : Container(color: Colors.black),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIdleView() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(30),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _isFingerDetected
                ? Colors.greenAccent.withOpacity(0.1)
                : Colors.white.withOpacity(0.05),
            border: Border.all(
              color: _isFingerDetected ? Colors.greenAccent : Colors.white24,
              width: 2,
            ),
          ),
          child: Icon(
            Icons.fingerprint,
            size: 100,
            color: _isFingerDetected ? Colors.greenAccent : Colors.white24,
          ),
        ),
        const SizedBox(height: 30),
        Text(
          _isFingerDetected ? "✓ Ready to Start" : "Place Finger on Camera",
          style: TextStyle(
            color: _isFingerDetected ? Colors.greenAccent : Colors.white70,
            fontSize: 22,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          _isFingerDetected
              ? "Cover the camera lens completely"
              : "Position your finger over the back camera",
          style: const TextStyle(
            color: Colors.white38,
            fontSize: 14,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 50),
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(30),
            boxShadow: _isFingerDetected
                ? [
              BoxShadow(
                color: Colors.redAccent.withOpacity(0.5),
                blurRadius: 20,
                spreadRadius: 2,
              ),
            ]
                : [],
          ),
          child: ElevatedButton(
            onPressed: _isFingerDetected ? _startMeasurement : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: _isFingerDetected ? Colors.redAccent : Colors.grey[800],
              padding: const EdgeInsets.symmetric(horizontal: 50, vertical: 18),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
              elevation: _isFingerDetected ? 10 : 2,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _isFingerDetected ? Icons.play_circle_filled : Icons.play_circle_outline,
                  color: Colors.white,
                ),
                const SizedBox(width: 10),
                const Text(
                  "START MEASUREMENT",
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 15),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Text(
            "⏱️ Duration: 60 seconds",
            style: TextStyle(color: Colors.white54, fontSize: 13),
          ),
        ),
      ],
    );
  }

  Widget _buildMeasuringView() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 1. Big BPM with Gradient
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: RadialGradient(
              colors: [
                Colors.redAccent.withOpacity(0.2),
                Colors.transparent,
              ],
            ),
            shape: BoxShape.circle,
          ),
          child: Column(
            children: [
              Text(
                "$_displayBpm",
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 90,
                  fontWeight: FontWeight.bold,
                  height: 1,
                ),
              ),
              const Text(
                "BPM",
                style: TextStyle(
                  color: Colors.redAccent,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 3,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 30),

        // 2. Signal Quality
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: _isFingerDetected
                ? Colors.green.withOpacity(0.2)
                : Colors.red.withOpacity(0.2),
            borderRadius: BorderRadius.circular(25),
            border: Border.all(
              color: _isFingerDetected ? Colors.greenAccent : Colors.redAccent,
              width: 1.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _isFingerDetected ? Icons.check_circle : Icons.error,
                color: _isFingerDetected ? Colors.greenAccent : Colors.redAccent,
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                _isFingerDetected
                    ? "Signal Quality: ${(_signalQuality * 100).toInt()}%"
                    : "No Signal Detected",
                style: TextStyle(
                  color: _isFingerDetected ? Colors.greenAccent : Colors.redAccent,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 35),

        // 3. Progress Bar
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            children: [
              Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: double.infinity,
                    height: 12,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: _elapsedSeconds / _measurementDuration,
                      backgroundColor: Colors.transparent,
                      color: _isFingerDetected ? Colors.greenAccent : Colors.redAccent,
                      minHeight: 12,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    "${_elapsedSeconds}s",
                    style: const TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                  Text(
                    "${_measurementDuration - _elapsedSeconds}s remaining",
                    style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                  Text(
                    "${_measurementDuration}s",
                    style: const TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 35),

        // 4. CHART (Original Simple Logic, but inside New Container UI)
        Container(
          height: 120, // Match new UI height
          width: double.infinity,
          margin: const EdgeInsets.symmetric(horizontal: 20),
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.03),
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: Colors.white.withOpacity(0.1)),
          ),
          child: _chartData.isNotEmpty
              ? LineChart(
            LineChartData(
              gridData: FlGridData(show: false),
              titlesData: FlTitlesData(show: false),
              borderData: FlBorderData(show: false),
              lineBarsData: [
                LineChartBarData(
                  spots: _chartData
                      .asMap()
                      .entries
                      .map((e) => FlSpot(e.key.toDouble(), e.value))
                      .toList(),
                  isCurved: true,
                  color: Colors.redAccent,
                  barWidth: 2,
                  dotData: FlDotData(show: false),
                  // Keep the simple Gradient from New UI for better looks, but Data is from Old Logic
                  belowBarData: BarAreaData(
                    show: true,
                    gradient: LinearGradient(
                      colors: [
                        Colors.redAccent.withOpacity(0.3),
                        Colors.redAccent.withOpacity(0.0),
                      ],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                  ),
                ),
              ],
              // Essential: Keep Y-Axis dynamic range small for "Zoomed In" effect (Old Logic)
              minY: _chartData.reduce((a, b) => a < b ? a : b) - 2,
              maxY: _chartData.reduce((a, b) => a > b ? a : b) + 2,
            ),
          )
              : Center(
            child: Text(
              "Waiting for signal...",
              style: TextStyle(color: Colors.white.withOpacity(0.3)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildResultView() {
    var metrics = _calculateHRVMetrics();
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(15),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.greenAccent.withOpacity(0.2), Colors.greenAccent.withOpacity(0.05)],
              ),
              borderRadius: BorderRadius.circular(15),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.assessment, color: Colors.greenAccent, size: 28),
                const SizedBox(width: 10),
                const Text("ANALYSIS COMPLETE", style: TextStyle(color: Colors.greenAccent, fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: 1)),
              ],
            ),
          ),
          const SizedBox(height: 25),
          GridView.count(
            shrinkWrap: true,
            crossAxisCount: 2,
            childAspectRatio: 1.3,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              _buildMetricCard("Avg BPM", "$_displayBpm", "BPM", Colors.redAccent, Icons.favorite),
              _buildMetricCard("SDNN", metrics['sdnn']!.toStringAsFixed(1), "ms", Colors.blueAccent, Icons.show_chart),
              _buildMetricCard("RMSSD", metrics['rmssd']!.toStringAsFixed(1), "ms", Colors.orangeAccent, Icons.graphic_eq),
              _buildMetricCard("pNN50", metrics['pnn50']!.toStringAsFixed(1), "%", Colors.purpleAccent, Icons.analytics),
              _buildMetricCard("MxDMn", metrics['mxdmn']!.toStringAsFixed(0), "ms", Colors.tealAccent, Icons.swap_vert),
              _buildMetricCard("AMo50", metrics['amo50']!.toStringAsFixed(1), "%", Colors.amberAccent, Icons.pie_chart),
            ],
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.white.withOpacity(0.1))),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.monitor_heart, color: Colors.white54, size: 20),
                const SizedBox(width: 10),
                Text("Total Heartbeats: ${_rrIntervalsHighPrecision.length}", style: const TextStyle(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
          const SizedBox(height: 30),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: _resetApp,
                icon: const Icon(Icons.refresh, color: Colors.white),
                label: const Text("New Test", style: TextStyle(color: Colors.white)),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 25, vertical: 15),
                  side: const BorderSide(color: Colors.white54),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
                ),
              ),
              const SizedBox(width: 15),
              ElevatedButton.icon(
                onPressed: _copyResults,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueAccent,
                  padding: const EdgeInsets.symmetric(horizontal: 25, vertical: 15),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
                  elevation: 5,
                ),
                icon: const Icon(Icons.copy, color: Colors.white),
                label: const Text("Copy Results", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildMetricCard(String title, String value, String unit, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [color.withOpacity(0.15), color.withOpacity(0.05)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: color.withOpacity(0.3), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title, style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w500)),
              Icon(icon, color: color.withOpacity(0.5), size: 18),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Flexible(child: Text(value, style: TextStyle(color: color, fontSize: 26, fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 4),
              Padding(padding: const EdgeInsets.only(bottom: 3), child: Text(unit, style: const TextStyle(color: Colors.white38, fontSize: 12))),
            ],
          ),
        ],
      ),
    );
  }
}