import 'dart:math' as math;
import 'package:camera/camera.dart';

class DSPService {
  final int _bufferSize = 256;
  
  // Buffers
  final List<double> rawSignalBuffer = [];
  final List<double> filteredSignal = [];
  final List<double> chartData = [];
  final List<double> rrIntervalsHighPrecision = [];
  final List<int> bpmBuffer = [];
  
  // Internal Filter Buffers
  final List<double> _maBuffer = [];
  final List<double> _baselineBuffer = [];
  final List<double> _integrationBuffer = [];
  double _lastBandpassed = 0.0;
  
  // State variables
  double? _lastPeakTimestamp;
  int _framesSinceLastPeak = 0;
  int _warmupFrames = 0;
  double signalQuality = 0.0;
  double adaptiveThreshold = 0.0;
  final List<double> _recentPeaks = [];
  
  bool isFingerDetected = false;
  int displayBpm = 0;
  bool _isProcessing = false;
  double? _lastFrameTimeMs;

  // Callback to update UI when new data arrives
  Function? onDataUpdated;

  double _movingAverage(double newValue, List<double> buffer, int windowSize) {
    buffer.add(newValue);
    if (buffer.length > windowSize) buffer.removeAt(0);
    return buffer.reduce((a, b) => a + b) / buffer.length;
  }

  void processImage(CameraImage image, bool isMeasuring) {
    if (_isProcessing) return;
    _isProcessing = true;

    double currentFrameTimeMs = DateTime.now().microsecondsSinceEpoch / 1000.0;
    double frameDuration = _lastFrameTimeMs != null ? (currentFrameTimeMs - _lastFrameTimeMs!) : 33.33;
    if (frameDuration <= 0 || frameDuration > 100) frameDuration = 33.33;
    _lastFrameTimeMs = currentFrameTimeMs;

    final int width = image.width;
    final int height = image.height;
    final int yStride = image.planes[0].bytesPerRow;
    final int uvStride = image.planes[1].bytesPerRow;
    final int uvPixelStride = image.planes[1].bytesPerPixel ?? 1;

    int centerX = width ~/ 2;
    int centerY = height ~/ 2;
    int range = 40;

    double sumR = 0, sumG = 0, sumB = 0;
    int count = 0;

    for (int y = centerY - range; y < centerY + range; y += 2) {
      for (int x = centerX - range; x < centerX + range; x += 2) {
        if (y >= 0 && y < height && x >= 0 && x < width) {
          int uvIndex = (y ~/ 2) * uvStride + (x ~/ 2) * uvPixelStride;
          int indexY = y * yStride + x;

          int Y = image.planes[0].bytes[indexY];
          int U = image.planes[1].bytes[uvIndex];
          int V = image.planes[2].bytes[uvIndex];

          int R = (Y + 1.370705 * (V - 128)).round().clamp(0, 255);
          int G = (Y - 0.337633 * (U - 128) - 0.698001 * (V - 128)).round().clamp(0, 255);
          int B = (Y + 1.732446 * (U - 128)).round().clamp(0, 255);

          sumR += R;
          sumG += G;
          sumB += B;
          count++;
        }
      }
    }

    if (count == 0) { _isProcessing = false; return; }
    
    double avgR = sumR / count;
    double avgG = sumG / count;
    double avgB = sumB / count;

    bool isFingerPresentNow = (avgR > 100 && avgR > avgG * 1.5 && avgR > avgB * 1.5);

    if (isFingerDetected != isFingerPresentNow) {
      isFingerDetected = isFingerPresentNow;
      onDataUpdated?.call();
    }

    if (!isFingerPresentNow) {
      resetSignalBuffers(resetWarmup: false); 
      _isProcessing = false;
      return;
    }

    rawSignalBuffer.add(avgR);
    if (rawSignalBuffer.length > _bufferSize) rawSignalBuffer.removeAt(0);
    if (rawSignalBuffer.length < 5) { _isProcessing = false; return; }

    _warmupFrames++;
    bool isWarmup = _warmupFrames < 150;

    double smoothed = _movingAverage(avgR, _maBuffer, 5);
    double baseline = _movingAverage(smoothed, _baselineBuffer, 60);
    double bandpassed = smoothed - baseline;

    double derivative = bandpassed - _lastBandpassed;
    _lastBandpassed = bandpassed;
    double squared = derivative * derivative;
    double integrated = _movingAverage(squared, _integrationBuffer, 10);

    filteredSignal.add(integrated);
    if (filteredSignal.length > _bufferSize) filteredSignal.removeAt(0);

    if (_recentPeaks.length >= 5) {
      double meanPeak = _recentPeaks.reduce((a, b) => a + b) / _recentPeaks.length;
      double varPeak = _recentPeaks.map((p) => math.pow(p - meanPeak, 2)).reduce((a, b) => a + b) / _recentPeaks.length;
      double stdPeak = math.sqrt(varPeak);
      double snr = meanPeak / (stdPeak > 0 ? stdPeak : 1);
      signalQuality = math.min(1.0, snr / 10.0);
    }

    if (filteredSignal.length >= 3 && !isWarmup) {
      double prev = filteredSignal[filteredSignal.length - 3];
      double curr = filteredSignal[filteredSignal.length - 2];
      double next = filteredSignal[filteredSignal.length - 1];

      List<double> recent = filteredSignal.length > 60 ? filteredSignal.sublist(filteredSignal.length - 60) : filteredSignal;
      double maxV = recent.reduce(math.max);
      adaptiveThreshold = adaptiveThreshold * 0.95 + (maxV * 0.5) * 0.05;

      _framesSinceLastPeak++;
      
      double avgRRMs = bpmBuffer.isNotEmpty ? 60000 / (bpmBuffer.reduce((a, b) => a + b) / bpmBuffer.length) : 800;
      int adaptiveRefractionFrames = (avgRRMs * 0.6 / 33.33).clamp(5, 30).toInt();

      if (curr > prev && curr > next && curr > adaptiveThreshold && _framesSinceLastPeak > adaptiveRefractionFrames) {
        
        double denominator = 2 * (prev - 2 * curr + next);
        double delta = denominator != 0 ? (prev - next) / denominator : 0.0;
        
        double exactPeakTime = currentFrameTimeMs - frameDuration + (delta * frameDuration);

        _recentPeaks.add(curr);
        if (_recentPeaks.length > 10) _recentPeaks.removeAt(0);

        if (_lastPeakTimestamp != null) {
          double rrInterval = exactPeakTime - _lastPeakTimestamp!;

          if (rrInterval >= 300 && rrInterval <= 2000) {
            if (isMeasuring) {
              rrIntervalsHighPrecision.add(rrInterval);
            }

            int instantBpm = (60000 / rrInterval).round();
            bpmBuffer.add(instantBpm);
            if (bpmBuffer.length > 5) bpmBuffer.removeAt(0);

            displayBpm = (bpmBuffer.reduce((a, b) => a + b) / bpmBuffer.length).round();
            onDataUpdated?.call();

            _framesSinceLastPeak = 0;
            _lastPeakTimestamp = exactPeakTime;
          } else if (rrInterval > 2000) {
            _lastPeakTimestamp = exactPeakTime;
            bpmBuffer.clear();
          }
        } else {
          _lastPeakTimestamp = exactPeakTime;
        }
      }
    }

    chartData.add(bandpassed);
    if (chartData.length > 150) chartData.removeAt(0);
    
    // Update chart periodically
    if (_framesSinceLastPeak % 3 == 0) {
        onDataUpdated?.call();
    }

    _isProcessing = false;
  }

  void resetSignalBuffers({bool resetWarmup = true}) {
    rawSignalBuffer.clear();
    filteredSignal.clear();
    bpmBuffer.clear();
    _framesSinceLastPeak = 0;
    _maBuffer.clear();
    _baselineBuffer.clear();
    _integrationBuffer.clear();
    _lastBandpassed = 0.0;
    _recentPeaks.clear();
    adaptiveThreshold = 0.0;
    _lastPeakTimestamp = null;
    _lastFrameTimeMs = null;
    if (resetWarmup) {
      _warmupFrames = 0;
    }
  }

  void forceWarmup() {
    _warmupFrames = 0;
    rrIntervalsHighPrecision.clear();
    displayBpm = 0;
    bpmBuffer.clear();
    chartData.clear();
  }
}
