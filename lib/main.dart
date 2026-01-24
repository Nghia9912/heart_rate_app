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
  // Lock orientation to portrait to prevent camera stream issues
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
  // --- HARDWARE CONTROLLERS ---
  CameraController? _controller;
  bool _isCameraInitialized = false;

  // --- STATE MANAGEMENT ---
  AppState _appState = AppState.idle;
  bool _isScanInProgress = false;
  Timer? _timer;
  int _elapsedSeconds = 0;
  final int _measurementDuration = 60; // Standard 60s measurement
  bool _isFingerDetected = false;

  // --- DATA VISUALIZATION ---
  final List<double> _chartData = [];
  final List<double> _rrIntervalsHighPrecision = []; // Stores exact ms durations
  final List<int> _bpmBuffer = []; // Buffer for smoothing UI display
  int _displayBpm = 0;

  // --- SIGNAL PROCESSING (DSP) VARIABLES ---
  final List<double> _rawSignalBuffer = [];
  final List<double> _filteredSignal = [];
  final int _bufferSize = 256;
  final List<double> _maBuffer = []; // Moving Average buffer

  // High-precision timing for Sub-frame Interpolation
  final Stopwatch _measurementStopwatch = Stopwatch();
  double? _lastPeakTimestamp;

  // Peak Detection Configuration
  int _framesSinceLastPeak = 0;
  final int _refractionPeriod = 12; // ~400ms refractory period to prevent double counting
  double _signalQuality = 0.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable(); // Prevent screen from sleeping during measurement
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

  // Handle App Lifecycle (Release camera when app is paused)
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      _controller?.dispose();
      setState(() {
        _isCameraInitialized = false;
        _isFingerDetected = false;
      });
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera();
    }
  }

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
      ResolutionPreset.low, // 320x240 is optimal for processing speed
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    try {
      await _controller!.initialize();
      // Flash must be ON (Torch mode) for PPG
      await _controller!.setFlashMode(FlashMode.torch);
      // Lock Exposure and Focus to prevent auto-adjustment artifacts
      await _controller!.setExposureMode(ExposureMode.locked);
      await _controller!.setFocusMode(FocusMode.locked);
      _controller!.startImageStream(_processImage);
      if (mounted) setState(() => _isCameraInitialized = true);
    } catch (e) {
      debugPrint("Camera Error: $e");
    }
  }

  // Simple Moving Average (SMA) filter for noise reduction
  double _movingAverage(double newValue, List<double> buffer, int windowSize) {
    buffer.add(newValue);
    if (buffer.length > windowSize) buffer.removeAt(0);
    return buffer.reduce((a, b) => a + b) / buffer.length;
  }

  // --- CORE IMAGE PROCESSING LOOP ---
  void _processImage(CameraImage image) {
    if (_isScanInProgress) return;
    _isScanInProgress = true;

    // 1. EXTRACT ROI (Region of Interest)
    // We analyze the central 80x80 pixels for luminance changes
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

    // Skip every 2nd pixel to optimize CPU usage
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

    // 2. FINGER DETECTION
    // Calculate Standard Deviation to check for uniformity (skin covers lens = low stdDev)
    for (int p in pixelSamples) {
      double diff = p - rawAvg;
      sumSquaredDiff += diff * diff;
    }
    double stdDev = math.sqrt(sumSquaredDiff / count);

    // Thresholds: Brightness must be adequate but not overexposed; StdDev must be low
    bool isFingerPresentNow = ((rawAvg > 30 && rawAvg < 255) && stdDev < 30);

    if (_isFingerDetected != isFingerPresentNow) {
      Future.microtask(() { if (mounted) setState(() => _isFingerDetected = isFingerPresentNow); });
    }

    if (!isFingerPresentNow) {
      _resetSignalBuffers();
      _isScanInProgress = false;
      return;
    }

    // 3. SIGNAL PRE-PROCESSING
    _rawSignalBuffer.add(rawAvg);
    if (_rawSignalBuffer.length > _bufferSize) _rawSignalBuffer.removeAt(0);
    if (_rawSignalBuffer.length < 5) { _isScanInProgress = false; return; }

    // Apply Low-pass Filter (Smoothing)
    double smoothed = _movingAverage(rawAvg, _maBuffer, 5);

    // Apply DC Removal (Baseline Detrending) using a 30-frame window
    double baseline = smoothed;
    if (_rawSignalBuffer.length > 30) {
      baseline = _rawSignalBuffer.sublist(_rawSignalBuffer.length - 30).reduce((a, b) => a + b) / 30;
    }
    double filtered = smoothed - baseline;

    _filteredSignal.add(filtered);
    if (_filteredSignal.length > _bufferSize) _filteredSignal.removeAt(0);

    // Calculate SQI (Signal Quality Index) for UI feedback
    if (_filteredSignal.length > 60) {
      List<double> recent = _filteredSignal.sublist(_filteredSignal.length - 60);
      double maxVal = recent.reduce((a, b) => a > b ? a : b);
      double minVal = recent.reduce((a, b) => a < b ? a : b);
      _signalQuality = math.min(1.0, (maxVal - minVal) / 5.0);
    }

    // 4. PEAK DETECTION & SUB-FRAME INTERPOLATION
    // We need at least 3 points to fit a parabola (Prev, Curr, Next)
    if (_filteredSignal.length >= 3) {
      double prev = _filteredSignal[_filteredSignal.length - 3];
      double curr = _filteredSignal[_filteredSignal.length - 2]; // Potential peak
      double next = _filteredSignal[_filteredSignal.length - 1];

      // Dynamic Adaptive Thresholding
      List<double> recent = _filteredSignal.length > 60 ? _filteredSignal.sublist(_filteredSignal.length - 60) : _filteredSignal;
      double minV = recent.reduce(math.min);
      double maxV = recent.reduce(math.max);
      double threshold = minV + (maxV - minV) * 0.5; // 50% amplitude threshold

      _framesSinceLastPeak++;

      // Peak Logic: Local Maxima + Above Threshold + Refraction Period
      if (curr > prev && curr > next && curr > threshold && _framesSinceLastPeak > _refractionPeriod) {

        // --- PARABOLIC INTERPOLATION LOGIC ---
        // Formula to find the exact sub-frame peak offset 'delta'
        double denominator = 2 * (prev - 2 * curr + next);
        double delta = 0.0;
        if (denominator != 0) {
          delta = (prev - next) / denominator;
        }

        // Convert frame index to high-precision timestamp using Stopwatch
        double currentFrameTimeMs = _measurementStopwatch.elapsedMicroseconds / 1000.0;
        double frameDuration = 33.33; // Approx duration for 30fps

        // Exact Peak Time = Current Time - 1 frame lag + Delta offset
        double exactPeakTime = currentFrameTimeMs - frameDuration + (delta * frameDuration);

        if (_lastPeakTimestamp != null) {
          double rrInterval = exactPeakTime - _lastPeakTimestamp!;

          // Physiologic Filter: Accept only 40-160 BPM (375ms - 1500ms)
          if (rrInterval >= 375 && rrInterval <= 1500) {

            // Artifact Rejection: Check for sudden jumps compared to average
            bool isValid = true;
            if (_bpmBuffer.isNotEmpty) {
              double avgBpm = _bpmBuffer.reduce((a, b) => a + b) / _bpmBuffer.length;
              double instantBpm = 60000 / rrInterval;
              // Reject if deviation > 20 BPM
              if ((instantBpm - avgBpm).abs() > 20) isValid = false;
            }

            if (isValid || _bpmBuffer.isEmpty) {
              if (_appState == AppState.measuring) {
                _rrIntervalsHighPrecision.add(rrInterval);
              }

              // Update Display BPM (Smoothed)
              int instantBpm = (60000 / rrInterval).round();
              _bpmBuffer.add(instantBpm);
              if (_bpmBuffer.length > 5) _bpmBuffer.removeAt(0);

              int displayVal = (_bpmBuffer.reduce((a, b) => a + b) / _bpmBuffer.length).round();
              Future.microtask(() { if (mounted) setState(() => _displayBpm = displayVal); });

              _framesSinceLastPeak = 0;
              _lastPeakTimestamp = exactPeakTime;
            }
          } else if (rrInterval > 2000) {
            // Reset logic if signal was lost for > 2 seconds
            _lastPeakTimestamp = exactPeakTime;
            _bpmBuffer.clear();
          }
        } else {
          _lastPeakTimestamp = exactPeakTime; // First peak detected
        }
      }
    }

    // Update real-time chart
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

  // --- HRV CALCULATION (TIME DOMAIN & BAEVSKY) ---
  Map<String, double> _calculateHRVMetrics() {
    if (_rrIntervalsHighPrecision.length < 20) {
      return {'sdnn': 0, 'rmssd': 0, 'pnn50': 0, 'mxdmn': 0, 'amo50': 0};
    }

    // 1. Outlier Removal using IQR (Interquartile Range) Method
    List<double> sorted = List.from(_rrIntervalsHighPrecision)..sort();
    int q1Index = sorted.length ~/ 4;
    int q3Index = (sorted.length * 3) ~/ 4;
    double q1 = sorted[q1Index];
    double q3 = sorted[q3Index];
    double iqr = q3 - q1;
    double lowerBound = q1 - 1.5 * iqr;
    double upperBound = q3 + 1.5 * iqr;

    List<double> cleanedRR = _rrIntervalsHighPrecision.where((rr) => rr >= lowerBound && rr <= upperBound).toList();
    if (cleanedRR.length < 10) cleanedRR = _rrIntervalsHighPrecision; // Fallback if too aggressive

    // 2. SDNN Calculation
    double mean = cleanedRR.reduce((a, b) => a + b) / cleanedRR.length;
    double variance = 0;
    for (var rr in cleanedRR) {
      variance += (rr - mean) * (rr - mean);
    }
    double sdnn = math.sqrt(variance / cleanedRR.length);

    // 3. RMSSD Calculation (Key metric for recovery)
    double sumSquaredDiff = 0;
    for (int i = 1; i < cleanedRR.length; i++) {
      double diff = cleanedRR[i] - cleanedRR[i - 1];
      sumSquaredDiff += diff * diff;
    }
    double rmssd = math.sqrt(sumSquaredDiff / (cleanedRR.length - 1));

    // 4. pNN50 Calculation
    int count50 = 0;
    for (int i = 1; i < cleanedRR.length; i++) {
      if ((cleanedRR[i] - cleanedRR[i - 1]).abs() > 50) {
        count50++;
      }
    }
    double pnn50 = (count50 / (cleanedRR.length - 1)) * 100;

    // 5. Baevsky Stress Index Metrics
    double maxRR = cleanedRR.reduce(math.max);
    double minRR = cleanedRR.reduce(math.min);
    double mxdmn = maxRR - minRR;

    // AMo50 (Amplitude of Mode)
    Map<int, int> histogram = {};
    for (var rr in cleanedRR) {
      int bucket = (rr / 50).round() * 50; // Bin size 50ms
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

  // --- APP CONTROL LOGIC ---
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

  // --- UI BUILDING BLOCKS ---
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) { if (!didPop) _handleBackPress(); },
      child: Scaffold(
        backgroundColor: Colors.grey[900],
        body: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              const Spacer(),
              if (_appState == AppState.idle) _buildIdleView(),
              if (_appState == AppState.measuring) _buildMeasuringView(),
              if (_appState == AppState.result) _buildResultView(),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              // Logo
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

              // 2. Tên App
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("HRV MONITOR", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
                  Text("Pro Edition", style: TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              ),
            ],
          ),

          //CAMERA PREVIEW
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                  color: _isFingerDetected ? Colors.greenAccent : Colors.redAccent,
                  width: 2
              ),
              boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 8)],
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
        Icon(Icons.fingerprint, size: 120,
            color: _isFingerDetected ? Colors.greenAccent : Colors.white24
        ),
        const SizedBox(height: 20),
        Text(
            _isFingerDetected ? "Ready" : "Place Finger on Camera",
            style: TextStyle(
                color: _isFingerDetected ? Colors.greenAccent : Colors.white70,
                fontSize: 24,
                fontWeight: FontWeight.bold
            )
        ),
        const SizedBox(height: 40),
        ElevatedButton(
          onPressed: _isFingerDetected ? _startMeasurement : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: _isFingerDetected ? Colors.redAccent : Colors.grey[800],
            padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
          ),
          child: const Text("START (60s)", style: TextStyle(fontSize: 18, color: Colors.white)),
        ),
      ],
    );
  }

  Widget _buildMeasuringView() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text("$_displayBpm", style: const TextStyle(color: Colors.white, fontSize: 80, fontWeight: FontWeight.bold)),
        const Text("BPM", style: TextStyle(color: Colors.redAccent, fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
              color: _isFingerDetected ? Colors.green.withOpacity(0.2) : Colors.red.withOpacity(0.2),
              borderRadius: BorderRadius.circular(20)
          ),
          child: Text(
            _isFingerDetected ? "Signal: Good (${(_signalQuality*100).toInt()}%)" : "No Signal",
            style: TextStyle(color: _isFingerDetected ? Colors.greenAccent : Colors.redAccent),
          ),
        ),
        const SizedBox(height: 30),
        SizedBox(
          width: 250,
          child: LinearProgressIndicator(
            value: _elapsedSeconds / _measurementDuration,
            backgroundColor: Colors.white10,
            color: _isFingerDetected ? Colors.greenAccent : Colors.red,
            minHeight: 8,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        const SizedBox(height: 8),
        Text("${_measurementDuration - _elapsedSeconds}s remaining",
            style: const TextStyle(color: Colors.white54)
        ),
        const SizedBox(height: 30),
        Container(
          height: 100,
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _chartData.isNotEmpty ? LineChart(
            LineChartData(
              gridData: FlGridData(show: false),
              titlesData: FlTitlesData(show: false),
              borderData: FlBorderData(show: false),
              lineBarsData: [
                LineChartBarData(
                  spots: _chartData.asMap().entries.map((e) => FlSpot(e.key.toDouble(), e.value)).toList(),
                  isCurved: true,
                  color: Colors.redAccent.withOpacity(0.8),
                  barWidth: 2,
                  dotData: FlDotData(show: false),
                  belowBarData: BarAreaData(show: true, color: Colors.redAccent.withOpacity(0.1)),
                ),
              ],
              minY: _chartData.reduce((a,b)=>a<b?a:b) - 2,
              maxY: _chartData.reduce((a,b)=>a>b?a:b) + 2,
            ),
          ) : Container(),
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
          const Text("ANALYSIS REPORT",
              style: TextStyle(color: Colors.greenAccent, fontSize: 20, fontWeight: FontWeight.bold)
          ),
          const SizedBox(height: 20),
          GridView.count(
            shrinkWrap: true,
            crossAxisCount: 2,
            childAspectRatio: 1.4,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              _buildMetricCard("Avg BPM", "$_displayBpm", "BPM", Colors.redAccent),
              _buildMetricCard("SDNN", metrics['sdnn']!.toStringAsFixed(1), "ms", Colors.blueAccent),
              _buildMetricCard("RMSSD", metrics['rmssd']!.toStringAsFixed(1), "ms", Colors.orangeAccent),
              _buildMetricCard("pNN50", metrics['pnn50']!.toStringAsFixed(1), "%", Colors.purpleAccent),
              _buildMetricCard("MxDMn", metrics['mxdmn']!.toStringAsFixed(0), "ms", Colors.tealAccent),
              _buildMetricCard("AMo50", metrics['amo50']!.toStringAsFixed(1), "%", Colors.amberAccent),
            ],
          ),
          const SizedBox(height: 20),
          Text("Total Beats: ${_rrIntervalsHighPrecision.length}",
              style: const TextStyle(color: Colors.white38)
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: _resetApp,
                icon: const Icon(Icons.refresh, color: Colors.white),
                label: const Text("Retry", style: TextStyle(color: Colors.white)),
              ),
              const SizedBox(width: 15),
              ElevatedButton.icon(
                onPressed: _copyResults,
                style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
                icon: const Icon(Icons.copy, color: Colors.white),
                label: const Text("Copy", style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildMetricCard(String title, String value, String unit, Color color) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(title, style: const TextStyle(color: Colors.white70, fontSize: 12)),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(value, style: TextStyle(color: color, fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(width: 4),
              Text(unit, style: const TextStyle(color: Colors.white38, fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }
}