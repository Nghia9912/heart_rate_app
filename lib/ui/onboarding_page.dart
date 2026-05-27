import 'package:flutter/material.dart';
import '../models/user_profile.dart';

class OnboardingPage extends StatefulWidget {
  final VoidCallback onCompleted;
  final UserProfile? initialProfile;

  const OnboardingPage({super.key, required this.onCompleted, this.initialProfile});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  int _age = 25;
  Gender _gender = Gender.male;
  double _weight = 70.0;
  double _height = 170.0;
  Goal _goal = Goal.health;

  @override
  void initState() {
    super.initState();
    if (widget.initialProfile != null) {
      _age = widget.initialProfile!.age;
      _gender = widget.initialProfile!.gender;
      _weight = widget.initialProfile!.weight;
      _height = widget.initialProfile!.height;
      _goal = widget.initialProfile!.goal;
    }
  }

  Future<void> _saveAndContinue() async {
    final profile = UserProfile(
      age: _age,
      gender: _gender,
      weight: _weight,
      height: _height,
      goal: _goal,
    );
    await UserProfile.saveProfile(profile);
    widget.onCompleted();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0a0a0a),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(widget.initialProfile == null ? "Welcome to HRV Monitor" : "Edit Profile", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Personalize Your Experience", style: TextStyle(color: Colors.redAccent, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            const Text("We use this data to provide accurate benchmarks for your heart rate and HRV.", style: TextStyle(color: Colors.white54, fontSize: 14)),
            const SizedBox(height: 30),

            _buildSectionTitle("Age: $_age years"),
            Slider(
              value: _age.toDouble(),
              min: 10, max: 100,
              activeColor: Colors.redAccent,
              inactiveColor: Colors.white24,
              onChanged: (val) => setState(() => _age = val.toInt()),
            ),
            const SizedBox(height: 20),

            _buildSectionTitle("Gender"),
            const SizedBox(height: 10),
            Row(
              children: Gender.values.map((g) {
                bool isSelected = _gender == g;
                return Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _gender = g),
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 5),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      decoration: BoxDecoration(
                        color: isSelected ? Colors.redAccent.withOpacity(0.2) : Colors.white.withOpacity(0.05),
                        border: Border.all(color: isSelected ? Colors.redAccent : Colors.white24),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      alignment: Alignment.center,
                      child: Text(g.name.toUpperCase(), style: TextStyle(color: isSelected ? Colors.redAccent : Colors.white70, fontWeight: FontWeight.bold)),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 30),

            _buildSectionTitle("Height: ${_height.toInt()} cm"),
            Slider(
              value: _height,
              min: 100, max: 250,
              activeColor: Colors.greenAccent,
              inactiveColor: Colors.white24,
              onChanged: (val) => setState(() => _height = val),
            ),
            const SizedBox(height: 20),

            _buildSectionTitle("Weight: ${_weight.toInt()} kg"),
            Slider(
              value: _weight,
              min: 30, max: 150,
              activeColor: Colors.blueAccent,
              inactiveColor: Colors.white24,
              onChanged: (val) => setState(() => _weight = val),
            ),
            const SizedBox(height: 30),

            _buildSectionTitle("Primary Goal"),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10, runSpacing: 10,
              children: Goal.values.map((g) {
                bool isSelected = _goal == g;
                return ChoiceChip(
                  label: Text(g.name.toUpperCase()),
                  selected: isSelected,
                  selectedColor: Colors.purpleAccent.withOpacity(0.3),
                  backgroundColor: Colors.white.withOpacity(0.05),
                  labelStyle: TextStyle(color: isSelected ? Colors.purpleAccent : Colors.white70, fontWeight: FontWeight.bold),
                  side: BorderSide(color: isSelected ? Colors.purpleAccent : Colors.white24),
                  onSelected: (val) {
                    if (val) setState(() => _goal = g);
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 50),

            SizedBox(
              width: double.infinity,
              height: 55,
              child: ElevatedButton(
                onPressed: _saveAndContinue,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                ),
                child: const Text("SAVE & CONTINUE", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600));
  }
}
