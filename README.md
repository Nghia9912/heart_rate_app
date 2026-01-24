# HRV Monitor Pro: Clinical-Grade Heart Rate Variability Analysis

![Flutter](https://img.shields.io/badge/Flutter-3.0%2B-blue) ![License](https://img.shields.io/badge/License-MIT-green) ![Status](https://img.shields.io/badge/Status-Production%20Ready-brightgreen)

## 🩺 Overview

**HRV Monitor Pro** is a mobile application built with Flutter that utilizes **Photoplethysmography (PPG)** to measure Heart Rate Variability (HRV) using only the smartphone's camera and flash.

Unlike standard heart rate apps that only calculate Beats Per Minute (BPM), this project focuses on millisecond-level precision to derive advanced mental and physical health metrics, such as **RMSSD** (Recovery Status) and the **Baevsky Stress Index**.

### 🚀 Key Technical Features

This project overcomes the hardware limitations of standard smartphone cameras (typically locked at 30fps / 33ms latency) by implementing advanced Digital Signal Processing (DSP) algorithms:

* **Sub-frame Parabolic Interpolation:** Utilizes a 3-point parabolic interpolation technique to reconstruct the true signal peak, improving temporal resolution from **33ms down to ~1-2ms**.
* **Adaptive Thresholding:** A dynamic peak detection algorithm that automatically adjusts to varying signal amplitudes, ensuring stability across different skin tones and lighting conditions.
* **Robust Signal Filtering:**
    * *Low-pass Filter:* Eliminates high-frequency sensor noise.
    * *DC Removal:* Removes baseline wander caused by respiration or motion artifacts.
* **Artifact Correction:** Implements the **IQR (Interquartile Range)** method to automatically detect and reject ectopic beats or motion-induced noise.
* **High-Precision Timing:** Uses a monotonic `Stopwatch` instead of `DateTime` to eliminate Operating System jitter and ensure accurate RR interval calculation.

## 📊 Metrics & Analysis

The application provides a comprehensive health report based on two analytical frameworks:

### 1. Time Domain Analysis (Western Standard)
* **Avg BPM:** Real-time average Heart Rate.
* **SDNN (ms):** Standard deviation of NN intervals. Indicates overall autonomic nervous system health.
* **RMSSD (ms):** Root mean square of successive differences. The **"Gold Standard"** for assessing parasympathetic activity and Post-workout Recovery.
* **pNN50 (%):** Percentage of successive RR intervals that differ by more than 50 ms.

### 2. Baevsky Stress Index (Russian Standard)
* **MxDMn (ms):** The difference between the longest and shortest RR interval (Variational range).
* **AMo50 (%):** Amplitude of Mode. A primary indicator of mental stress levels and sympathetic nervous system activation.

## 🛠 Installation & Setup

### Requirements
* Flutter SDK: >=3.0.0
* Physical Android/iOS Device (Simulators are not supported due to Camera/Flash requirements).

### Steps
1.  **Clone the repository:**
    ```bash
    git clone https://github.com/Nghia9912/heart_rate_app.git
    cd heart_rate_app
    ```
2.  **Install dependencies:**
    ```bash
    flutter pub get
    ```

3.  **Permissions:**
    * *Android:* Permissions are handled in `AndroidManifest.xml`.

4.  **Run the app:**
    ```bash
    flutter run
    ```

## 📚 Signal Processing Pipeline

The real-time DSP pipeline operates as follows:

1.  **Image Acquisition:** Capture YUV420 image stream from the Camera Controller.
2.  **ROI Extraction:** Extract the central Region of Interest (80x80 pixels).
3.  **Raw Signal:** Calculate the average Luminance (Y-channel) of the ROI.
4.  **Preprocessing:**
    * Smoothing (Moving Average).
    * Baseline Detrending (DC Removal).
5.  **Peak Detection:** Identify potential peaks using Adaptive Thresholds.
6.  **Refinement:** Apply Parabolic Interpolation to locate the exact sub-frame peak timestamp.
7.  **HRV Calculation:** Compute statistical metrics from the cleaned RR Interval series.

## ⚠️ Disclaimer

This application is developed for research, educational, and personal wellness purposes. While it utilizes high-precision algorithms, **it is NOT a medical device** and should not be used for medical diagnosis or treatment. Please consult a healthcare professional for any health concerns.

---
*Developed by Nghia9912*
