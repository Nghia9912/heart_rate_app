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
  CameraController? _controller;
  bool _isCameraInitialized = false;

  AppState _appState = AppState.idle;
  bool _isScanInProgress = false;
  Timer? _timer;
  int _elapsedSeconds = 0;
  final int _measurementDuration = 60;
  bool _isFingerDetected = false;

  final List<double> _chartData = [];
  final List<double> _rrIntervalsHighPrecision = []; // Lưu RR interval dạng double (ms) chính xác cao
  final List<int> _bpmBuffer = [];
  int _displayBpm = 0;

  // --- SIGNAL PROCESSING VARIABLES ---
  final List<double> _rawSignalBuffer = [];
  final List<double> _filteredSignal = [];
  final int _bufferSize = 256;

  // High-precision timing
  final Stopwatch _measurementStopwatch = Stopwatch();
  double? _lastPeakTimestamp; // Thời gian của đỉnh trước (tính bằng ms từ lúc bắt đầu đo)

  // Peak Detection Variables
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

  // Bộ lọc trung bình trượt đơn giản để làm mượt nhiễu hạt
  double _movingAverage(double newValue, List<double> buffer, int windowSize) {
    buffer.add(newValue);
    if (buffer.length > windowSize) buffer.removeAt(0);
    return buffer.reduce((a, b) => a + b) / buffer.length;
  }
  final List<double> _maBuffer = [];

  void _processImage(CameraImage image) {
    if (_isScanInProgress) return;
    _isScanInProgress = true;

    // 1. TÍNH TOÁN ĐỘ SÁNG TRUNG BÌNH (ROI)
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

    // Nhảy cóc 2 pixel để tối ưu hiệu năng
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

    // 2. PHÁT HIỆN NGÓN TAY (FINGER DETECTION)
    for (int p in pixelSamples) {
      double diff = p - rawAvg;
      sumSquaredDiff += diff * diff;
    }
    double stdDev = math.sqrt(sumSquaredDiff / count);

    // Ngưỡng phát hiện ngón tay: Sáng vừa phải và đồng nhất
    bool isFingerPresentNow = ((rawAvg > 30 && rawAvg < 255) && stdDev < 30);

    if (_isFingerDetected != isFingerPresentNow) {
      Future.microtask(() { if (mounted) setState(() => _isFingerDetected = isFingerPresentNow); });
    }

    if (!isFingerPresentNow) {
      _resetSignalBuffers();
      _isScanInProgress = false;
      return;
    }

    // 3. XỬ LÝ TÍN HIỆU (DSP)
    // Lưu vào buffer thô
    _rawSignalBuffer.add(rawAvg);
    if (_rawSignalBuffer.length > _bufferSize) _rawSignalBuffer.removeAt(0);
    if (_rawSignalBuffer.length < 5) { _isScanInProgress = false; return; }

    // Làm mượt tín hiệu (Smoothing)
    double smoothed = _movingAverage(rawAvg, _maBuffer, 5);

    // Loại bỏ đường nền (DC Removal) bằng cách trừ đi trung bình của 30 frame trước
    double baseline = smoothed;
    if (_rawSignalBuffer.length > 30) {
      baseline = _rawSignalBuffer.sublist(_rawSignalBuffer.length - 30).reduce((a, b) => a + b) / 30;
    }
    double filtered = smoothed - baseline;

    _filteredSignal.add(filtered);
    if (_filteredSignal.length > _bufferSize) _filteredSignal.removeAt(0);

    // Tính chỉ số chất lượng (Signal Quality)
    if (_filteredSignal.length > 60) {
      List<double> recent = _filteredSignal.sublist(_filteredSignal.length - 60);
      double maxVal = recent.reduce((a, b) => a > b ? a : b);
      double minVal = recent.reduce((a, b) => a < b ? a : b);
      _signalQuality = math.min(1.0, (maxVal - minVal) / 5.0);
    }

    // 4. THUẬT TOÁN DÒ ĐỈNH + NỘI SUY (PARABOLIC INTERPOLATION)
    // Cần ít nhất 3 điểm để thực hiện nội suy (Trước, Giữa, Sau)
    if (_filteredSignal.length >= 3) {
      double prev = _filteredSignal[_filteredSignal.length - 3]; // y[n-1]
      double curr = _filteredSignal[_filteredSignal.length - 2]; // y[n]  (Đỉnh tiềm năng)
      double next = _filteredSignal[_filteredSignal.length - 1]; // y[n+1]

      // Cập nhật ngưỡng động
      List<double> recent = _filteredSignal.length > 60 ? _filteredSignal.sublist(_filteredSignal.length - 60) : _filteredSignal;
      double minV = recent.reduce(math.min);
      double maxV = recent.reduce(math.max);
      double threshold = minV + (maxV - minV) * 0.5; // Ngưỡng 50%

      _framesSinceLastPeak++;

      // Điều kiện 1: Đây là cực đại cục bộ (Lớn hơn cả 2 bên)
      // Điều kiện 2: Vượt qua ngưỡng động
      // Điều kiện 3: Đã qua thời gian trơ (Refraction Period)
      if (curr > prev && curr > next && curr > threshold && _framesSinceLastPeak > _refractionPeriod) {

        // --- BÍ MẬT CỦA WELLTORY: NỘI SUY PARABOLIC ---
        // Tìm độ lệch đỉnh (Sub-frame offset)
        // Công thức: d = (y_prev - y_next) / (2 * (y_prev - 2*y_curr + y_next))
        // d là khoảng cách từ 'curr' đến đỉnh thực tế (đơn vị: frame)
        double denominator = 2 * (prev - 2 * curr + next);
        double delta = 0.0;
        if (denominator != 0) {
          delta = (prev - next) / denominator;
        }

        // Lấy thời gian hiện tại chính xác bằng Stopwatch
        double currentFrameTimeMs = _measurementStopwatch.elapsedMicroseconds / 1000.0;

        // Thời điểm thực tế của đỉnh = Thời gian frame hiện tại - 1 frame (do ta đang xét frame giữa) + delta
        // Giả sử 1 frame ~ 33.33ms
        double frameDuration = 33.33;
        double exactPeakTime = currentFrameTimeMs - frameDuration + (delta * frameDuration);

        if (_lastPeakTimestamp != null) {
          double rrInterval = exactPeakTime - _lastPeakTimestamp!;

          // Bộ lọc logic: Chỉ nhận nhịp tim 40-160 BPM
          if (rrInterval >= 375 && rrInterval <= 1500) {

            // Outlier Filter (Loại bỏ nhịp nhảy cóc)
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

              // Cập nhật BPM hiển thị (làm tròn để dễ nhìn)
              int instantBpm = (60000 / rrInterval).round();
              _bpmBuffer.add(instantBpm);
              if (_bpmBuffer.length > 5) _bpmBuffer.removeAt(0); // Chỉ lấy TB 5 nhịp gần nhất cho mượt

              int displayVal = (_bpmBuffer.reduce((a, b) => a + b) / _bpmBuffer.length).round();
              Future.microtask(() { if (mounted) setState(() => _displayBpm = displayVal); });

              _framesSinceLastPeak = 0;
              _lastPeakTimestamp = exactPeakTime; // Lưu lại mốc thời gian siêu chính xác
            }
          } else if (rrInterval > 2000) {
            // Reset nếu mất tín hiệu quá lâu
            _lastPeakTimestamp = exactPeakTime;
            _bpmBuffer.clear();
          }
        } else {
          _lastPeakTimestamp = exactPeakTime; // Nhịp đầu tiên
        }
      }
    }

    // Vẽ biểu đồ (vẫn dùng filtered để vẽ cho mượt mắt)
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

  // TÍNH TOÁN HRV VỚI ĐỘ CHÍNH XÁC CAO
  Map<String, double> _calculateHRVMetrics() {
    if (_rrIntervalsHighPrecision.length < 20) {
      return {'sdnn': 0, 'rmssd': 0, 'pnn50': 0, 'mxdmn': 0, 'amo50': 0};
    }

    // 1. Loại bỏ nhiễu bằng phương pháp IQR (Interquartile Range)
    List<double> sorted = List.from(_rrIntervalsHighPrecision)..sort();
    int q1Index = sorted.length ~/ 4;
    int q3Index = (sorted.length * 3) ~/ 4;
    double q1 = sorted[q1Index];
    double q3 = sorted[q3Index];
    double iqr = q3 - q1;
    double lowerBound = q1 - 1.5 * iqr;
    double upperBound = q3 + 1.5 * iqr;

    List<double> cleanedRR = _rrIntervalsHighPrecision.where((rr) => rr >= lowerBound && rr <= upperBound).toList();
    if (cleanedRR.length < 10) cleanedRR = _rrIntervalsHighPrecision; // Fallback nếu lọc quá tay

    // 2. Tính SDNN (Standard Deviation of NN intervals)
    double mean = cleanedRR.reduce((a, b) => a + b) / cleanedRR.length;
    double variance = 0;
    for (var rr in cleanedRR) {
      variance += (rr - mean) * (rr - mean);
    }
    double sdnn = math.sqrt(variance / cleanedRR.length);

    // 3. Tính RMSSD (Root Mean Square of Successive Differences) - Quan trọng nhất cho hồi phục
    double sumSquaredDiff = 0;
    for (int i = 1; i < cleanedRR.length; i++) {
      double diff = cleanedRR[i] - cleanedRR[i - 1];
      sumSquaredDiff += diff * diff;
    }
    double rmssd = math.sqrt(sumSquaredDiff / (cleanedRR.length - 1));

    // 4. Tính pNN50
    int count50 = 0;
    for (int i = 1; i < cleanedRR.length; i++) {
      if ((cleanedRR[i] - cleanedRR[i - 1]).abs() > 50) {
        count50++;
      }
    }
    double pnn50 = (count50 / (cleanedRR.length - 1)) * 100;

    // 5. Baevsky Metrics
    double maxRR = cleanedRR.reduce(math.max);
    double minRR = cleanedRR.reduce(math.min);
    double mxdmn = maxRR - minRR;

    // AMo50 (Amplitude of Mode)
    Map<int, int> histogram = {};
    for (var rr in cleanedRR) {
      int bucket = (rr / 50).round() * 50; // Gom nhóm mỗi 50ms
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
    // Bắt đầu đồng hồ bấm giờ độ phân giải cao
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
          title: const Text("Dừng đo?", style: TextStyle(color: Colors.white)),
          content: const Text("Dữ liệu hiện tại sẽ bị mất.", style: TextStyle(color: Colors.white70)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text("Tiếp tục", style: TextStyle(color: Colors.white)),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text("Dừng", style: TextStyle(color: Colors.redAccent)),
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
HRV REPORT (High Precision)
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
      const SnackBar(content: Text("Đã sao chép kết quả vào bộ nhớ đệm!")),
    );
  }

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
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("HRV MONITOR", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
              Text("Welltory-Grade Precision", style: TextStyle(color: Colors.grey, fontSize: 12)),
            ],
          ),
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
            _isFingerDetected ? "Sẵn sàng" : "Đặt ngón tay lên Camera",
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
          child: const Text("BẮT ĐẦU ĐO (60s)", style: TextStyle(fontSize: 18, color: Colors.white)),
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
            _isFingerDetected ? "Tín hiệu Tốt (${(_signalQuality*100).toInt()}%)" : "Mất tín hiệu!",
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
        Text("${_measurementDuration - _elapsedSeconds}s còn lại",
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
          const Text("KẾT QUẢ PHÂN TÍCH",
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
              _buildMetricCard("Nhịp tim TB", "$_displayBpm", "BPM", Colors.redAccent),
              _buildMetricCard("SDNN", metrics['sdnn']!.toStringAsFixed(1), "ms", Colors.blueAccent),
              _buildMetricCard("RMSSD", metrics['rmssd']!.toStringAsFixed(1), "ms", Colors.orangeAccent),
              _buildMetricCard("pNN50", metrics['pnn50']!.toStringAsFixed(1), "%", Colors.purpleAccent),
              _buildMetricCard("MxDMn", metrics['mxdmn']!.toStringAsFixed(0), "ms", Colors.tealAccent),
              _buildMetricCard("AMo50", metrics['amo50']!.toStringAsFixed(1), "%", Colors.amberAccent),
            ],
          ),
          const SizedBox(height: 20),
          Text("Tổng số nhịp: ${_rrIntervalsHighPrecision.length}",
              style: const TextStyle(color: Colors.white38)
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: _resetApp,
                icon: const Icon(Icons.refresh, color: Colors.white),
                label: const Text("Đo lại", style: TextStyle(color: Colors.white)),
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