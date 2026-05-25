# Project Summary: Offline Kokoro TTS Integration for macOS (Intel)

This document summarizes the development journey, architectural adjustments, technical challenges, and ultimate solutions implemented to build a local, offline Text-to-Speech (TTS) app on an Intel-based Mac.

---

## 1. Overview of the Application
The application is a native macOS desktop utility that provides **100% offline, private text-to-speech synthesis** using the high-quality, open-source **Kokoro-82M** model. 

### Core Features
*   **SwiftUI Frontend**: A modern, clean, and interactive user interface built with Apple's native framework. Includes an expandable text area and a live dropdown list for picking different voice profiles.
*   **Immediate Playback**: Audio frames are processed on-the-fly and spoken immediately through the Mac's hardware speakers using native `AVAudioPlayer` structures.
*   **Low Resource Footprint**: Optimized to use minimal RAM and run entirely on local CPU cycles without calling costly cloud APIs.

---

## 2. System Architecture & How It Works

Because the machine is an **Intel Mac (2017 MacBook Pro)** running **macOS 15 Sequoia** via **OpenCore Legacy Patcher**, a hybrid client-server architecture was designed to replace the hardware-locked Apple Silicon dependencies:

```text
┌─────────────────────────────────┐        HTTP POST (Text, Voice)       ┌─────────────────────────────────┐
│     SwiftUI Frontend App        │ ───────────────────────────────────> │     Python FastAPI Backend      │
│ (Handles UI & Audio Playback)  │ <─────────────────────────────────── │   (Runs Kokoro CPU Inference)   │
└─────────────────────────────────┘          WAV Audio Bytes Stream      └─────────────────────────────────┘
```

1.  **User Action**: The user inputs text into the SwiftUI app, selects a voice attribute (e.g., `af_heart`), and clicks **Speak Text**.
2.  **API Bridge**: The Swift frontend sends a local HTTP `POST` network request carrying JSON payload data to an isolated local background port (`http://localhost:8000/tts`).
3.  **Inference**: A minimalist Python **FastAPI / Uvicorn** background server picks up the request. It processes the text using a `KPipeline` object, running the model strictly on the Intel CPU.
4.  **Encoding**: The resulting raw audio sound waves are structured into standard WAV byte sequences using `soundfile` and streamed directly back across the local loopback network.
5.  **Output**: Swift reads the raw binary data directly into an `AVAudioPlayer` memory wrapper and triggers immediate native hardware audio channel playback.

---

## 3. Key Technical Challenges & Solutions

During development, we navigated unique challenges related to legacy hardware compatibility, Swift Package Manager configurations, and Python dependency version mismatches:

### 🧩 Challenge 1: Apple Silicon Hardware Locks (MLX Framework)
*   **Problem**: Initial attempts used a native Swift port of Kokoro (`kokoro-ios`) built on Apple's `mlx-swift` engine. This threw severe runtime crashes because MLX relies on the **Unified Memory Architecture** and hardware matrices unique to Apple Silicon (M1/M2/M3/M4) chips. It cannot run on Intel x86_64 processors.
*   **Solution**: Pivoted to a **Local Hybrid Server Bridge Model**. The frontend UI remains native Swift, but the core neural calculations are safely handled by a local Python execution environment powered by an Intel CPU-optimized version of PyTorch.

### 📦 Challenge 2: Headless Command Line Application Stalling
*   **Problem**: Since the app layout was initialized using `swift package init --type executable`, macOS targeted it strictly as a silent background terminal tool, causing the SwiftUI desktop window to freeze or remain completely invisible.
*   **Solution**: Implemented a specialized `NSApplicationDelegateAdaptor` framework hook (`AppDelegate`) directly inside the main application entry point to explicitly alter the app's activation policy to `.regular` and forcefully move the GUI window layout directly onto the active desktop layer.

### 🧱 Challenge 3: App Transport Security (ATS) Network Blockages
*   **Problem**: macOS blocks all non-secure cleartext connections (`http://`) by default, throwing a "Resource could not be loaded" runtime exception when trying to access the local server.
*   **Solution**: Swapped out the raw IP `127.0.0.1` for `localhost` to hit local loopback exemptions, and injected explicit `NSAllowsArbitraryLoads` permissions into the compiled binary target by mapping a custom metadata mapping key inside `Package.swift`.

### 🚨 Challenge 4: The NumPy 1.x vs 2.x Conflict & Subprocess Reload Freezes
*   **Problem**: Pip installed the latest NumPy 2.x by default, which is binary-incompatible with PyTorch’s older Intel Mac wheels (`2.2.2`), crashing the pipeline. Furthermore, using `uvicorn --reload` spawned child worker threads using the global system paths, bypassing our virtual environment configurations and throwing an unexpected `ImportError` on `CustomAlbert`.
*   **Solution**: 
    1. Recreated a strictly isolated environment using **Python 3.12** and locked down `numpy<2`.
    2. Locked `transformers<4.40.0` to retain full compatibility with the Intel Mac PyTorch release window.
    3. Rewrote `app.py` using **Zero-NumPy logic**, pulling values using native Python float list iterations (`.tolist()`) to completely bypass array mapping collisions.
    4. Dropped the `--reload` parameter flag to execute the web application safely inside a single stable process container.

---

## 4. Final Optimization & Environment Summary

The local Python backend workspace has been stripped of unnecessary packages (like `torchvision` and `torchaudio`), saving nearly 1GB of disk space and removing all runtime memory bloat.

### Minimal Dependency Blueprint (`requirements.txt`)
```text
fastapi>=0.110.0
uvicorn>=0.28.0
soundfile>=0.12.1
kokoro>=0.9.4
misaki[en]>=0.4.0
transformers<4.40.0
torch==2.2.2
```

### Verified Operational Sequence
1.  **Launch Backend**: `/Users/burak/projects/speechapp/.venv/bin/uvicorn app:app --port 8000`
2.  **Launch Frontend**: `swift run -c release`
3.  **Outcome**: The app establishes immediate local network handshakes, processes text seamlessly on an Intel CPU, and yields fast, clear, offline text-to-speech playback!
