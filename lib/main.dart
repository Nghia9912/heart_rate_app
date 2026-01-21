import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';

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
  bool _isFlashOn = false;

  @override
  void initState() {
    super.initState();
    _initializeCamera(); // Tự động khởi động camera khi mở app
  }

  // Hàm khởi tạo Camera một lần duy nhất
  Future<void> _initializeCamera() async {
    var status = await Permission.camera.request();
    if (status.isGranted) {
      final cameras = await availableCameras();
      // cameras[0] thường là camera sau của điện thoại
      _controller = CameraController(
        cameras[0],
        ResolutionPreset.low, // Chọn độ phân giải thấp để xử lý nhanh
        enableAudio: false,   // Tắt thu âm để tránh hỏi quyền Micro
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await _controller!.initialize();

      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
        });
      }
    }
  }

  // Hàm chỉ dùng để bật tắt đèn, không khởi tạo lại camera
  Future<void> _toggleFlash() async {
    if (_controller != null && _controller!.value.isInitialized) {
      if (_isFlashOn) {
        await _controller!.setFlashMode(FlashMode.off);
        _isFlashOn = false;
      } else {
        await _controller!.setFlashMode(FlashMode.torch);
        _isFlashOn = true;
      }
      setState(() {}); // Cập nhật giao diện nút bấm
    }
  }

  @override
  void dispose() {
    // Giải phóng camera khi tắt app để tránh tốn pin
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("HRV Monitor - Realme 14")),
      body: Column(
        children: [
          // Phần 1: Màn hình Preview Camera (Để bạn thấy ngón tay đỏ rực)
          Expanded(
            child: Center(
              child: _isCameraInitialized
                  ? CameraPreview(_controller!)
                  : const CircularProgressIndicator(),
            ),
          ),
          // Phần 2: Nút điều khiển
          Padding(
            padding: const EdgeInsets.all(20),
            child: ElevatedButton.icon(
              onPressed: _toggleFlash,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 15),
                backgroundColor: _isFlashOn ? Colors.orange : Colors.blue,
              ),
              icon: Icon(_isFlashOn ? Icons.flash_off : Icons.flash_on),
              label: Text(_isFlashOn ? "Tắt đèn Flash" : "Bật đèn Flash"),
            ),
          ),
        ],
      ),
    );
  }
}