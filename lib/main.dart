import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:fl_chart/fl_chart.dart'; // Chart library

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: HRVMonitorPage()));
}

class HRVMonitorPage extends StatefulWidget {
  const HRVMonitorPage({super.key});
  @override
  State<HRVMonitorPage> createState() => _HRVMonitorPageState();
}

class _HRVMonitorPageState extends State<HRVMonitorPage> {
  CameraController? _controller;
  bool _isCameraInitialized = false;
  bool _isScanInProgress = false;

  // Chart data points
  final List<double> _dataPoints = [];

  // --- HEART RATE VARIABLES ---
  double _currentValue = 0.0;
  int _bpm = 0; // Heart rate result

  // Peak detection algorithm variables
  final List<double> _windowBuffer = []; // Buffer to calculate average threshold
  DateTime? _lastBeatTime; // Timestamp of the previous beat

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    // Request permission
    var status = await Permission.camera.request();
    if (status.isGranted) {
      final cameras = await availableCameras();
      _controller = CameraController(
        cameras[0],
        ResolutionPreset.low,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      try {
        await _controller!.initialize();
        await _controller!.setFlashMode(FlashMode.torch);
        await _controller!.setExposureMode(ExposureMode.locked);
        await _controller!.setFocusMode(FocusMode.locked);
        await _controller!.startImageStream(_processImage);
        if (mounted) setState(() => _isCameraInitialized = true);
      } catch (e) {
        debugPrint("Error: $e");
      }
    }
  }

  void _processImage(CameraImage image) {
    if (_isScanInProgress) return;
    _isScanInProgress = true;

    // 1. Calculate average brightness
    int sum = 0;
    int count = 0;
    final int yStride = image.planes[0].bytesPerRow;
    int centerX = image.width ~/ 2;
    int centerY = image.height ~/ 2;
    int range = 20;
    for (int y = centerY - range; y < centerY + range; y++) {
      for (int x = centerX - range; x < centerX + range; x++) {
        sum += image.planes[0].bytes[y * yStride + x];
        count++;
      }
    }
    double avg = sum / count;

    // --- BEAT DETECTION ALGORITHM ---

    // 2. Add to buffer to calculate "Dynamic Threshold"
    // This threshold adapts over time to the user's skin brightness
    _windowBuffer.add(avg);
    if (_windowBuffer.length > 30) _windowBuffer.removeAt(0); // Keep 30 frames (~1 second)

    // Calculate average of the last 1 second
    double threshold = _windowBuffer.reduce((a, b) => a + b) / _windowBuffer.length;

    // 3. Beat detection: If current value is slightly GREATER than average
    // AND at least 300ms has passed since last beat (Refractory period to avoid double counting)
    DateTime now = DateTime.now();
    if (avg > threshold + 0.5 &&
        (_lastBeatTime == null || now.difference(_lastBeatTime!).inMilliseconds > 300)) {

      if (_lastBeatTime != null) {
        // Calculate BPM based on time difference
        int msDiff = now.difference(_lastBeatTime!).inMilliseconds;
        double instantBpm = 60000 / msDiff; // 60,000 ms in 1 minute

        // Filter noise (Typical heart rate is between 40-180)
        if (instantBpm > 40 && instantBpm < 180) {
          if (mounted) {
            setState(() {
              _bpm = instantBpm.toInt(); // Update BPM on screen
            });
          }
        }
      }
      _lastBeatTime = now; // Save timestamp of this beat
    }

    // Update chart
    if (mounted) {
      setState(() {
        _currentValue = avg;
        _dataPoints.add(avg);
        if (_dataPoints.length > 100) _dataPoints.removeAt(0);
      });
    }
    _isScanInProgress = false;
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: const Text("HRV Monitor"), backgroundColor: Colors.grey[900]),
      body: Column(
        children: [
          // Display Heart Rate prominently
          Container(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                const Text("HEART RATE (BPM)", style: TextStyle(color: Colors.grey, fontSize: 16)),
                Text(
                    _bpm > 0 ? "$_bpm" : "--",
                    style: const TextStyle(color: Colors.greenAccent, fontSize: 80, fontWeight: FontWeight.bold)
                ),
              ],
            ),
          ),

          // Waveform chart
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: _dataPoints.isNotEmpty
                  ? LineChart(
                LineChartData(
                  gridData: const FlGridData(show: false),
                  titlesData: const FlTitlesData(show: false),
                  borderData: FlBorderData(show: false),
                  lineBarsData: [
                    LineChartBarData(
                      spots: _dataPoints.asMap().entries.map((e) => FlSpot(e.key.toDouble(), e.value)).toList(),
                      isCurved: true,
                      color: Colors.red,
                      barWidth: 3,
                      dotData: const FlDotData(show: false),
                    ),
                  ],
                  // Auto-scale for better visualization
                  minY: _dataPoints.reduce((a, b) => a < b ? a : b) - 2,
                  maxY: _dataPoints.reduce((a, b) => a > b ? a : b) + 2,
                ),
              )
                  : const Center(child: CircularProgressIndicator()),
            ),
          ),
        ],
      ),
    );
  }
}