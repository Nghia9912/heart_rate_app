import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

enum Gender { male, female, other }
enum Goal { fitness, cardio, health, stress }

class UserProfile {
  final int age;
  final Gender gender;
  final double weight; // in kg
  final double height; // in cm
  final Goal goal;

  UserProfile({
    required this.age,
    required this.gender,
    required this.weight,
    required this.height,
    required this.goal,
  });

  Map<String, dynamic> toMap() {
    return {
      'age': age,
      'gender': gender.name,
      'weight': weight,
      'height': height,
      'goal': goal.name,
    };
  }

  factory UserProfile.fromMap(Map<String, dynamic> map) {
    return UserProfile(
      age: map['age'] ?? 25,
      gender: Gender.values.firstWhere((e) => e.name == map['gender'], orElse: () => Gender.male),
      weight: map['weight']?.toDouble() ?? 70.0,
      height: map['height']?.toDouble() ?? 170.0,
      goal: Goal.values.firstWhere((e) => e.name == map['goal'], orElse: () => Goal.health),
    );
  }

  static const String _prefKey = 'user_profile_data';

  static Future<void> saveProfile(UserProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, json.encode(profile.toMap()));
  }

  static Future<UserProfile?> loadProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final dataString = prefs.getString(_prefKey);
    if (dataString != null) {
      try {
        final map = json.decode(dataString);
        return UserProfile.fromMap(map);
      } catch (e) {
        return null;
      }
    }
    return null;
  }
}
