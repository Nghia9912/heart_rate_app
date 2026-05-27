import 'dart:math' as math;

class HRVAnalyzer {
  static Map<String, double> calculateHRVMetrics(List<double> rrIntervals) {
    if (rrIntervals.length < 20) {
      return {'sdnn': 0, 'rmssd': 0, 'pnn50': 0, 'mxdmn': 0, 'amo50': 0};
    }

    // Outlier Removal using IQR
    List<double> sorted = List.from(rrIntervals)..sort();
    int q1Index = sorted.length ~/ 4;
    int q3Index = (sorted.length * 3) ~/ 4;
    double q1 = sorted[q1Index];
    double q3 = sorted[q3Index];
    double iqr = q3 - q1;
    double lowerBound = q1 - 1.5 * iqr;
    double upperBound = q3 + 1.5 * iqr;

    List<double> cleanedRR = rrIntervals.where((rr) => rr >= lowerBound && rr <= upperBound).toList();
    if (cleanedRR.length < 10) cleanedRR = rrIntervals; // Fallback if too aggressive

    // 1. SDNN (Task Force 1996 Sample Variance N-1)
    double mean = cleanedRR.reduce((a, b) => a + b) / cleanedRR.length;
    double variance = 0;
    for (var rr in cleanedRR) {
      variance += (rr - mean) * (rr - mean);
    }
    double sdnn = math.sqrt(variance / (cleanedRR.length > 1 ? cleanedRR.length - 1 : 1));

    // 2. RMSSD
    double sumSquaredDiff = 0;
    for (int i = 1; i < cleanedRR.length; i++) {
      double diff = cleanedRR[i] - cleanedRR[i - 1];
      sumSquaredDiff += diff * diff;
    }
    double rmssd = math.sqrt(sumSquaredDiff / (cleanedRR.length > 1 ? cleanedRR.length - 1 : 1));

    // 3. pNN50
    int count50 = 0;
    for (int i = 1; i < cleanedRR.length; i++) {
      if ((cleanedRR[i] - cleanedRR[i - 1]).abs() > 50) {
        count50++;
      }
    }
    double pnn50 = cleanedRR.length > 1 ? (count50 / (cleanedRR.length - 1)) * 100 : 0;

    // 4. Baevsky Stress Index Components
    double maxRR = cleanedRR.reduce(math.max);
    double minRR = cleanedRR.reduce(math.min);
    double mxdmn = maxRR - minRR;

    Map<int, int> histogram = {};
    for (var rr in cleanedRR) {
      int bucket = (rr / 50).round() * 50;
      histogram[bucket] = (histogram[bucket] ?? 0) + 1;
    }
    int maxCount = histogram.values.isEmpty ? 0 : histogram.values.reduce(math.max);
    double amo50 = cleanedRR.isNotEmpty ? (maxCount / cleanedRR.length) * 100 : 0;

    return {
      'sdnn': sdnn,
      'rmssd': rmssd,
      'pnn50': pnn50,
      'mxdmn': mxdmn,
      'amo50': amo50,
    };
  }
}
