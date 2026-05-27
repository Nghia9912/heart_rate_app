import '../models/user_profile.dart';

class BenchmarkResult {
  final String title;
  final String description;
  final String level; // "Excellent", "Good", "Normal", "Needs Improvement"
  final double scoreRatio; // 0.0 to 1.0 for UI gauge

  BenchmarkResult({
    required this.title,
    required this.description,
    required this.level,
    required this.scoreRatio,
  });
}

class BenchmarkUtils {
  static int calculateMaxHR(int age) {
    return 220 - age;
  }

  static double calculateBMI(double weight, double heightCm) {
    double heightM = heightCm / 100;
    if (heightM <= 0) return 0;
    return weight / (heightM * heightM);
  }

  static String getBMICategory(double bmi) {
    if (bmi < 18.5) return "Underweight";
    if (bmi >= 18.5 && bmi < 24.9) return "Normal Weight";
    if (bmi >= 25 && bmi < 29.9) return "Overweight";
    return "Obese";
  }

  static BenchmarkResult evaluateHeartRate(int avgBpm, UserProfile profile) {
    int maxHr = calculateMaxHR(profile.age);
    
    // Evaluate based on Goal
    double targetMin = 0.5;
    double targetMax = 0.85;
    String goalText = "";

    switch (profile.goal) {
      case Goal.fitness:
        targetMin = 0.6; targetMax = 0.7; // Fat burn / Fitness
        goalText = "Fitness/Fat Burn";
        break;
      case Goal.cardio:
        targetMin = 0.7; targetMax = 0.85; // Cardio Training
        goalText = "Cardio Health";
        break;
      case Goal.health:
      case Goal.stress:
        targetMin = 0.5; targetMax = 0.6; // Light activity / Health
        goalText = "General Health/Relax";
        break;
    }

    double minHrGoal = maxHr * targetMin;
    double maxHrGoal = maxHr * targetMax;

    String level = "Normal";
    double ratio = 0.5;
    String desc = "Your avg HR is $avgBpm BPM.";

    if (avgBpm < minHrGoal) {
      level = "Below Target";
      ratio = 0.2;
      desc = "Your HR ($avgBpm) is below your $goalText target ($minHrGoal - $maxHrGoal).";
    } else if (avgBpm > maxHrGoal) {
      level = "Above Target";
      ratio = 0.9;
      desc = "Your HR ($avgBpm) is higher than your $goalText target ($minHrGoal - $maxHrGoal).";
    } else {
      level = "On Target";
      ratio = 0.5;
      desc = "Perfect! Your HR ($avgBpm) is within your $goalText target ($minHrGoal - $maxHrGoal).";
    }

    // Special case for resting HR (if they are just measuring resting HR without exercising)
    // We assume if it's < 100 it might just be resting. Let's provide resting assessment.
    if (avgBpm < 100) {
       if (avgBpm >= 60 && avgBpm <= 80) {
         level = "Good Resting HR";
         ratio = 0.7;
         desc = "Your resting HR ($avgBpm) is in a healthy range (60-80 BPM).";
       } else if (avgBpm < 60) {
         level = "Excellent (Athletic)";
         ratio = 0.9;
         desc = "Your resting HR ($avgBpm) is very low, common in well-trained athletes.";
       } else {
         level = "Elevated Resting HR";
         ratio = 0.3;
         desc = "Your resting HR ($avgBpm) is slightly elevated (>80 BPM).";
       }
    }

    return BenchmarkResult(
      title: "Heart Rate Assessment",
      description: desc,
      level: level,
      scoreRatio: ratio,
    );
  }

  static BenchmarkResult evaluateHRV(double sdnn, UserProfile profile) {
    // Rough estimation of normal SDNN based on age
    // 20s: 50-100+
    // 30s: 40-80+
    // 40s: 30-70+
    // 50s: 25-60+
    // 60+: 20-50+
    double normalMin = 30.0;
    double excellentMin = 60.0;

    if (profile.age < 30) {
      normalMin = 40; excellentMin = 70;
    } else if (profile.age < 40) {
      normalMin = 35; excellentMin = 60;
    } else if (profile.age < 50) {
      normalMin = 30; excellentMin = 50;
    } else if (profile.age < 60) {
      normalMin = 25; excellentMin = 40;
    } else {
      normalMin = 20; excellentMin = 35;
    }

    String level;
    double ratio;
    String desc;

    if (sdnn >= excellentMin) {
      level = "Excellent";
      ratio = 0.9;
      desc = "Your HRV (SDNN: ${sdnn.toStringAsFixed(1)}) is excellent for your age (${profile.age}). Great recovery!";
    } else if (sdnn >= normalMin) {
      level = "Good";
      ratio = 0.6;
      desc = "Your HRV (SDNN: ${sdnn.toStringAsFixed(1)}) is normal/good for your age (${profile.age}).";
    } else {
      level = "Needs Improvement";
      ratio = 0.2;
      desc = "Your HRV (SDNN: ${sdnn.toStringAsFixed(1)}) is below average for your age. Ensure proper rest and recovery.";
    }

    return BenchmarkResult(
      title: "HRV (SDNN) Assessment",
      description: desc,
      level: level,
      scoreRatio: ratio,
    );
  }
}
