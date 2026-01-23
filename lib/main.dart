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
  CameraController? _controller;
  bool _isCameraInitialized = false;

  AppState _appState = AppState.idle;
  bool _isScanInProgress = false;
  Timer? _timer;
  int _elapsedSeconds = 0;
  final int _measurementDuration = 60;

  bool _isFingerDetected = false;

  // --- DATA ---
  final List<double> _chartData = [];
  final List<int> _nnIntervals = []; // RR intervals in ms
  final List<int> _bpmBuffer = [];
  int _displayBpm = 0;

  // --- IMPROVED SIGNAL PROCESSING ---
  final List<double> _rawSignalBuffer = [];
  final List<double> _filteredSignal = [];
  final int _bufferSize = 256; // ~8.5 seconds at 30fps

  // Simple moving average filter instead of Butterworth
  final int _movingAvgWindow = 3;
  final List<double> _signalHistory = [];

  // Peak detection
  double _adaptiveThreshold = 0;
  DateTime? _lastPeakTime;
  final List<double> _peakBuffer = [];
  int _refractionPeriod = 10; // ~333ms at 30fps (min 180 BPM)

  // Quality metrics
  double _signalQuality = 0.0;
  int _framesSinceLastPeak = 0;

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
    CameraDescription selectedCamera = cameras.first;
    for (var cam in cameras) {
      if (cam.lensDirection == CameraLensDirection.back) {
        selectedCamera = cam;
        break;
      }
    }

    if (_controller != null) await _controller!.dispose();

    _controller = CameraController(
      selectedCamera,
      ResolutionPreset.low,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    try {
      await _controller!.initialize();
      await _controller!.setFlashMode(FlashMode.torch);
      await _controller!.setExposureMode(ExposureMode.locked);
      await _controller!.setFocusMode(FocusMode.locked);
      _controller!.startImageStream(_processImage);
      if (mounted) setState(() => _isCameraInitialized = true);
    } catch (e) {
      debugPrint("Camera Error: $e");
    }
  }

  // Simple moving average filter
  double _applySmoothingFilter(double input) {
    _signalHistory.add(input);
    if (_signalHistory.length > _movingAvgWindow) {
      _signalHistory.removeAt(0);
    }
    return _signalHistory.reduce((a, b) => a + b) / _signalHistory.length;
  }

  void _processImage(CameraImage image) {
    if (_isScanInProgress) return;
    _isScanInProgress = true;

    final int width = image.width;
    final int height = image.height;
    final int yStride = image.planes[0].bytesPerRow;

    // INCREASED ROI - larger sampling area
    int centerX = width ~/ 2;
    int centerY = height ~/ 2;
    int range = 40; // Increased from 20 to 40

    int sum = 0;
    int count = 0;
    double sumSquaredDiff = 0.0;
    List<int> pixelSamples = [];

    // Sample every 2 pixels for performance
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

    if (count == 0) {
      _isScanInProgress = false;
      return;
    }

    double rawAvg = sum / count;

    // IMPROVED FINGER DETECTION - More lenient
    for (int p in pixelSamples) {
      double diff = p - rawAvg;
      sumSquaredDiff += diff * diff;
    }
    double stdDev = math.sqrt(sumSquaredDiff / count);

    // Detect finger when brightness changes (either darker OR brighter than ambient)
    // AND pixels are relatively uniform (low stdDev)
    bool isFingerPresentNow = (
        (rawAvg > 30 && rawAvg < 240) && // Wide brightness range
            stdDev < 25 // More tolerance for variation
    );

    if (_isFingerDetected != isFingerPresentNow) {
      Future.microtask(() {
        if (mounted) setState(() => _isFingerDetected = isFingerPresentNow);
      });
    }

    if (!isFingerPresentNow) {
      _rawSignalBuffer.clear();
      _filteredSignal.clear();
      _bpmBuffer.clear();
      _peakBuffer.clear();
      _framesSinceLastPeak = 0;
      _isScanInProgress = false;
      return;
    }

    // Add to raw buffer
    _rawSignalBuffer.add(rawAvg);
    if (_rawSignalBuffer.length > _bufferSize) {
      _rawSignalBuffer.removeAt(0);
    }

    // Need at least 10 samples to start filtering
    if (_rawSignalBuffer.length < 10) {
      _isScanInProgress = false;
      return;
    }

    // APPLY SMOOTHING FILTER
    double filtered = _applySmoothingFilter(rawAvg);

    // Normalize signal (remove DC component)
    if (_rawSignalBuffer.length > 30) {
      double baseline = _rawSignalBuffer.sublist(_rawSignalBuffer.length - 30).reduce((a, b) => a + b) / 30;
      filtered = filtered - baseline;
    }

    _filteredSignal.add(filtered);
    if (_filteredSignal.length > _bufferSize) {
      _filteredSignal.removeAt(0);
    }

    // CALCULATE SIGNAL QUALITY
    if (_filteredSignal.length > 60) {
      double variance = 0;
      double mean = _filteredSignal.sublist(_filteredSignal.length - 60).reduce((a, b) => a + b) / 60;
      for (var val in _filteredSignal.sublist(_filteredSignal.length - 60)) {
        variance += (val - mean) * (val - mean);
      }
      variance /= 60;
      // Higher variance = better signal quality (more pulsation)
      _signalQuality = math.min(1.0, variance / 3);
    }

    // ADAPTIVE THRESHOLD PEAK DETECTION
    if (_filteredSignal.length >= 60) { // ~2 seconds
      // Calculate adaptive threshold from recent signal
      List<double> recentSignal = _filteredSignal.sublist(_filteredSignal.length - 60);
      double maxVal = recentSignal.reduce((a, b) => a > b ? a : b);
      double minVal = recentSignal.reduce((a, b) => a < b ? a : b);
      double amplitude = maxVal - minVal;

      // Threshold is 50% of amplitude above the minimum
      _adaptiveThreshold = minVal + amplitude * 0.5;

      _framesSinceLastPeak++;

      // PEAK DETECTION with refraction period
      if (filtered > _adaptiveThreshold &&
          amplitude > 0.5 && // Minimum signal amplitude
          _framesSinceLastPeak > _refractionPeriod) {
        // Check if this is a local maximum
        bool isLocalMax = true;
        if (_filteredSignal.length >= 3) {
          double prev = _filteredSignal[_filteredSignal.length - 2];
          if (filtered <= prev) isLocalMax = false;
        }

        if (isLocalMax) {
          DateTime now = DateTime.now();

          if (_lastPeakTime != null) {
            int rrInterval = now.difference(_lastPeakTime!).inMilliseconds;

            // Valid heart rate range: 40-200 BPM (300-1500 ms)
            if (rrInterval >= 300 && rrInterval <= 1500) {
              double instantBpm = 60000 / rrInterval;

              // IMPROVED OUTLIER REJECTION
              bool isValid = true;
              if (_bpmBuffer.length >= 3) {
                double avgBpm = _bpmBuffer.reduce((a, b) => a + b) / _bpmBuffer.length;
                double stdDevBpm = 0;
                for (var bpm in _bpmBuffer) {
                  stdDevBpm += (bpm - avgBpm) * (bpm - avgBpm);
                }
                stdDevBpm = math.sqrt(stdDevBpm / _bpmBuffer.length);

                // Reject if more than 2.5 standard deviations away OR more than 20 BPM difference
                if ((instantBpm - avgBpm).abs() > math.max(20, stdDevBpm * 2.5)) {
                  isValid = false;
                }
              }

              if (isValid) {
                if (_appState == AppState.measuring) {
                  _nnIntervals.add(rrInterval);
                }

                _bpmBuffer.add(instantBpm.toInt());
                if (_bpmBuffer.length > 8) _bpmBuffer.removeAt(0); // Increased averaging window

                int displayVal = (_bpmBuffer.reduce((a, b) => a + b) / _bpmBuffer.length).round();

                Future.microtask(() {
                  if (mounted) setState(() => _displayBpm = displayVal);
                });

                _framesSinceLastPeak = 0;
              }
            }
          }
          _lastPeakTime = now;
        }
      }
    }

    // Update chart with filtered signal
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

  // HRV METRICS CALCULATION
  Map<String, double> _calculateHRVMetrics() {
    if (_nnIntervals.length < 10) {
      return {
        'sdnn': 0,
        'rmssd': 0,
        'pnn50': 0,
        'mxdmn': 0,
        'amo50': 0,
      };
    }

    // SDNN - Standard deviation of NN intervals
    double mean = _nnIntervals.reduce((a, b) => a + b) / _nnIntervals.length;
    double variance = 0;
    for (var nn in _nnIntervals) {
      variance += (nn - mean) * (nn - mean);
    }
    double sdnn = math.sqrt(variance / _nnIntervals.length);

    // RMSSD - Root mean square of successive differences
    double sumSquaredDiff = 0;
    for (int i = 1; i < _nnIntervals.length; i++) {
      double diff = (_nnIntervals[i] - _nnIntervals[i - 1]).toDouble();
      sumSquaredDiff += diff * diff;
    }
    double rmssd = math.sqrt(sumSquaredDiff / (_nnIntervals.length - 1));

    // pNN50 - Percentage of successive differences > 50ms
    int count50 = 0;
    for (int i = 1; i < _nnIntervals.length; i++) {
      if ((_nnIntervals[i] - _nnIntervals[i - 1]).abs() > 50) {
        count50++;
      }
    }
    double pnn50 = (count50 / (_nnIntervals.length - 1)) * 100;

    // MxDMn - Difference between max and min NN interval
    int maxNN = _nnIntervals.reduce((a, b) => a > b ? a : b);
    int minNN = _nnIntervals.reduce((a, b) => a < b ? a : b);
    double mxdmn = (maxNN - minNN).toDouble();

    // AMo50 - Mode amplitude (simplified calculation)
    Map<int, int> histogram = {};
    for (var nn in _nnIntervals) {
      int bucket = (nn / 50).round() * 50; // 50ms bins
      histogram[bucket] = (histogram[bucket] ?? 0) + 1;
    }
    int maxCount = histogram.values.reduce((a, b) => a > b ? a : b);
    double amo50 = (maxCount / _nnIntervals.length) * 100;

    return {
      'sdnn': sdnn,
      'rmssd': rmssd,
      'pnn50': pnn50,
      'mxdmn': mxdmn,
      'amo50': amo50,
    };
  }

  void _startMeasurement() {
    setState(() {
      _appState = AppState.measuring;
      _nnIntervals.clear();
      _bpmBuffer.clear();
      _elapsedSeconds = 0;
      _displayBpm = 0;
    });

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        if (_isFingerDetected) {
          setState(() {
            _elapsedSeconds++;
          });
          if (_elapsedSeconds >= _measurementDuration) {
            _finishMeasurement();
          }
        }
      }
    });
  }

  void _finishMeasurement() {
    _timer?.cancel();
    setState(() {
      _appState = AppState.result;
    });
  }

  void _resetApp() {
    setState(() {
      _appState = AppState.idle;
      _elapsedSeconds = 0;
      _nnIntervals.clear();
      _chartData.clear();
      _displayBpm = 0;
      _bpmBuffer.clear();
      _isFingerDetected = false;
      _filteredSignal.clear();
      _rawSignalBuffer.clear();
      _peakBuffer.clear();
    });
  }

  void _copyResults() {
    var metrics = _calculateHRVMetrics();
    String data = """
HRV REPORT
Date: ${DateTime.now().toString()}
Avg BPM: $_displayBpm
Total Beats: ${_nnIntervals.length}
SDNN: ${metrics['sdnn']!.toStringAsFixed(1)} ms
RMSSD: ${metrics['rmssd']!.toStringAsFixed(1)} ms
pNN50: ${metrics['pnn50']!.toStringAsFixed(1)} %
MxDMn: ${metrics['mxdmn']!.toStringAsFixed(0)} ms
AMo50: ${metrics['amo50']!.toStringAsFixed(1)} %
    """;
    Clipboard.setData(ClipboardData(text: data));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Copied to clipboard!")),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: Opacity(
                opacity: 0.3,
                child: _chartData.isNotEmpty
                    ? LineChart(
                  LineChartData(
                    gridData: const FlGridData(show: false),
                    titlesData: const FlTitlesData(show: false),
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
                        barWidth: 3,
                        dotData: const FlDotData(show: false),
                      ),
                    ],
                    minY: _chartData.isNotEmpty
                        ? _chartData.reduce((a, b) => a < b ? a : b) - 2
                        : 0,
                    maxY: _chartData.isNotEmpty
                        ? _chartData.reduce((a, b) => a > b ? a : b) + 2
                        : 100,
                  ),
                )
                    : Container(),
              ),
            ),
            Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("HRV MONITOR",
                              style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 18)),
                          Text("Professional Edition",
                              style: TextStyle(color: Colors.grey, fontSize: 12)),
                        ],
                      ),
                      Column(
                        children: [
                          Container(
                            width: 80,
                            height: 80,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                  color: _isFingerDetected
                                      ? Colors.greenAccent
                                      : Colors.redAccent,
                                  width: 3),
                              boxShadow: const [
                                BoxShadow(color: Colors.black45, blurRadius: 10)
                              ],
                            ),
                            child: ClipOval(
                              child: _isCameraInitialized
                                  ? CameraPreview(_controller!)
                                  : const CircularProgressIndicator(),
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            "Quality: ${(_signalQuality * 100).toInt()}%",
                            style: TextStyle(
                              color: _signalQuality > 0.5
                                  ? Colors.greenAccent
                                  : Colors.orangeAccent,
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                if (_appState == AppState.idle) ...[
                  Icon(Icons.fingerprint,
                      size: 100,
                      color: _isFingerDetected ? Colors.greenAccent : Colors.grey),
                  const SizedBox(height: 20),
                  Text(
                      _isFingerDetected ? "Tín hiệu ổn định" : "Đặt ngón tay lên Camera",
                      style: TextStyle(
                          color: _isFingerDetected
                              ? Colors.greenAccent
                              : Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.bold)),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 40, vertical: 10),
                    child: Text(
                      "Giữ tay nhẹ nhàng. Ứng dụng sẽ tự động đo khi tín hiệu ổn định.",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                  const SizedBox(height: 30),
                  ElevatedButton(
                    onPressed: _isFingerDetected ? _startMeasurement : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isFingerDetected
                          ? Colors.redAccent
                          : Colors.grey[800],
                      padding: const EdgeInsets.symmetric(
                          horizontal: 50, vertical: 20),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30)),
                    ),
                    child: const Text("BẮT ĐẦU ĐO (1 PHÚT)",
                        style: TextStyle(fontSize: 18, color: Colors.white)),
                  ),
                ],
                if (_appState == AppState.measuring) ...[
                  Text("$_displayBpm BPM",
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 60,
                          fontWeight: FontWeight.bold)),
                  Text(
                      _isFingerDetected
                          ? "Đang phân tích... (${_nnIntervals.length} beats)"
                          : "⚠️ TÍN HIỆU KÉM!",
                      style: TextStyle(
                          color: _isFingerDetected
                              ? Colors.greenAccent
                              : Colors.redAccent,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 40),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40),
                    child: Column(
                      children: [
                        LinearProgressIndicator(
                          value: _elapsedSeconds / _measurementDuration,
                          backgroundColor: Colors.white10,
                          color: _isFingerDetected ? Colors.greenAccent : Colors.red,
                          minHeight: 10,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          "${_measurementDuration - _elapsedSeconds} giây còn lại",
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                ],
                if (_appState == AppState.result) ...[
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 20),
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white10,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Builder(
                      builder: (context) {
                        var metrics = _calculateHRVMetrics();
                        return Column(
                          children: [
                            const Text("KẾT QUẢ PHÂN TÍCH",
                                style: TextStyle(
                                    color: Colors.greenAccent,
                                    fontWeight: FontWeight.bold)),
                            const SizedBox(height: 20),
                            _buildResultRow("Avg BPM", "$_displayBpm", "bpm"),
                            _buildResultRow("SDNN",
                                metrics['sdnn']!.toStringAsFixed(1), "ms"),
                            _buildResultRow("RMSSD",
                                metrics['rmssd']!.toStringAsFixed(1), "ms"),
                            _buildResultRow("pNN50",
                                metrics['pnn50']!.toStringAsFixed(1), "%"),
                            const Divider(color: Colors.white24),
                            _buildResultRow("MxDMn",
                                metrics['mxdmn']!.toStringAsFixed(0), "ms"),
                            _buildResultRow("AMo50",
                                metrics['amo50']!.toStringAsFixed(1), "%"),
                            const SizedBox(height: 10),
                            Text(
                              "Total Beats: ${_nnIntervals.length}",
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 12),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TextButton.icon(
                        onPressed: _resetApp,
                        icon: const Icon(Icons.refresh, color: Colors.white),
                        label: const Text("Đo lại",
                            style: TextStyle(color: Colors.white)),
                      ),
                      const SizedBox(width: 20),
                      ElevatedButton.icon(
                        onPressed: _copyResults,
                        style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.blueAccent),
                        icon: const Icon(Icons.copy, color: Colors.white),
                        label: const Text("Copy kết quả",
                            style: TextStyle(color: Colors.white)),
                      ),
                    ],
                  ),
                ],
                const Spacer(),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultRow(String label, String value, String unit) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(color: Colors.white70, fontSize: 16)),
          Text("$value $unit",
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}