# Project Summary: Offline Kokoro TTS Integration for macOS (Intel)

This document summarizes the development journey, architectural adjustments, technical challenges, and ultimate solutions implemented to build a local, offline Text-to-Speech (TTS) app on an Intel-based Mac.

---

## 1. Overview of the Application
The application is a native macOS desktop utility that provides **100% offline, private text-to-speech synthesis** using the high-quality, open-source **Kokoro-82M** model. 

### Core Features
*   **Pure SwiftUI 6 Frontend**: A modern, responsive user interface built using Apple's declarative UI framework, fully compiled under strict Swift 6 data-isolation parameters.
*   **Low-Latency Async Streaming**: Audio frames are spoken progressively as they generate, reducing the time-to-first-word significantly on older Intel processors.
*   **Subprocess Lifetime Automation**: The app automatically boots up and tears down a hidden Python background engine within the bundle bundle namespace without requiring terminal orchestration.
*   **Visual Handshake Tracker**: Displays a loading spinner when launching (*"Starting system infrastructure..."*) and unlocks the full UI automatically only when a successful port verification returns (*"Engine Ready"*).

---

## 2. System Architecture & How It Works

Because the machine is an **Intel Mac (2017 MacBook Pro)** running **macOS 15 Sequoia** via **OpenCore Legacy Patcher**, the app follows a local hybrid streaming client-server structure:

```text
┌─────────────────────────────────┐   HTTP POST (Chunk Request)    ┌─────────────────────────────────┐
│     SwiftUI 6 Frontend App      │ ─────────────────────────────> │     Python FastAPI Backend      │
│ (Asynchronously Streams Audio)  │ <───────────────────────────── │   (Compiles Pure Python Lists)  │
└─────────────────────────────────┘     Continuous WAV Byte Stream └─────────────────────────────────┘
```

1.  **Launch Handshake**: On startup, a shared actor-isolated manager class triggers the internal embedded backend engine binary file. It monitors the network gateway iteratively via standard background async task workers.
2.  **User Action**: The user selects a voice embedding matrix profile (e.g., `af_heart`), inputs string sentences, and clicks **Stream Text**.
3.  **Generator Streaming**: The Python engine captures the payload. Instead of accumulating frames via heavy libraries, it converts individual array pieces into native Python float lists (`.tolist()`), structures them into micro-WAV bytes via `soundfile`, and immediately `yield`s them out down a persistent `StreamingResponse` network pipe.
4.  **Buffer Playback Interception**: Swift captures the incoming response stream using `URLSession.shared.bytes`. The very second the internal buffer hits a predefined threshold size (~1 second of audio data), an `AVAudioPlayer` initialization snapshot plays back instantly while the remaining chunks stream down the background thread concurrently.

---

## 3. Key Technical Challenges & Solutions

### 🧩 Challenge 1: Apple Silicon Hardware Locks (MLX Framework)
*   **Problem**: Native ports of Kokoro (`kokoro-ios`) require Apple Silicon's Unified Memory Architecture (UMA) and AMX instructions. Running them on an Intel x86_64 CPU causes an instant hardware instruction crash.
*   **Solution**: Pivoted to a **Local Hybrid Server Bridge Model**. The frontend is native Swift, but the core calculations run over a highly stripped-down Python environment powered by an Intel CPU-compatible version of PyTorch (`2.2.2`).

### 🧱 Challenge 2: App Transport Security (ATS) Network Blockages
*   **Problem**: macOS blocks all cleartext `http://` links by default, causing a network failure when hitting the local endpoint.
*   **Solution**: Changed connection targeting definitions to hit `localhost`, and appended structural exception keys (`NSAllowsArbitraryLoads`) directly into the compiled target metadata using custom string linker flags inside `Package.swift`.

### 🚨 Challenge 3: NumPy 1.x vs 2.x Conflict & PyInstaller Subprocess Crashes
*   **Problem**: Pip targets NumPy 2.x by default, which is binary-incompatible with PyTorch’s legacy Intel Mac packages. Additionally, compiling via PyInstaller resulted in quiet termination exit faults because the `transformers` library, `spacy`, and `language_tags` database dictionaries missed their nested configuration JSON metadata payloads.
*   **Solution**:
    1. Forced a fallback configuration profile inside our requirements structure mapping (`transformers<4.40.0` and `numpy<2`).
    2. Rewrote `app.py` as a **Zero-NumPy execution script** that relies on native Python array transformations to eliminate memory structure crashes completely.
    3. Added strict `--collect-all` and `--collect-data` parameters for `spacy`, `language_tags`, and `espeakng_loader` inside PyInstaller.
    4. Added a programmatic entry block to anchor the file thread: `if __name__ == "__main__": uvicorn.run(...)`.

### ⚡ Challenge 4: Swift 6 Strict Concurrency Isolation Deficiencies
*   **Problem**: Trying to trace the server startup status using traditional Foundation `Timer` objects failed under Swift 6's compilation checks, throwing severe `non-Sendable cross-actor data race capture` safety warnings.
*   **Solution**: Abandoned legacy timers entirely. Rewrote the network verification tracker inside `BackendProcessManager` to run within a modern Swift Concurrency task container context wrapped securely under the **`@MainActor`** wrapper. The background loop now checks the local server status safely using non-blocking **`Task.sleep(nanoseconds:)`** intervals, satisfying strict memory access rules cleanly.

---

## 4. Final Environment & Dependency Blueprint

### Core Dependencies (`requirements.txt`)
```text
fastapi>=0.110.0
uvicorn>=0.28.0
soundfile>=0.12.1
kokoro>=0.9.4
misaki[en]>=0.4.0
transformers<4.40.0
torch==2.2.2
```

### Verified Compilation Routine
To deploy the final binary bundle securely inside your production project path, run the optimization workflow commands:
```bash
# 1. Clean old tracking cache files
rm -rf .build

# 2. Compile the fully isolated, data-race free release build layout
swift run -c release
```


## Python Build Command

- builds executable from app.py
- executable placed in './dist/app'
- should be moved in to `/Users/burak/projects/speechapp/speechapp/Sources/speechapp/Resources` with the name `tts_backend` to be packeaged by swift pm. 



```py
/Users/burak/projects/speechapp/.venv/bin/pyinstaller --onefile \
  --collect-all transformers \
  --collect-all spacy \
  --collect-all en_core_web_sm \
  --collect-all uvicorn \
  --collect-all scipy \
  --collect-data soundfile \
  --collect-data language_tags \
  --collect-data phonemizer \
  --collect-data misaki \
  --collect-data espeakng_loader \
  --copy-metadata torch \
  --copy-metadata transformers \
  --copy-metadata fastapi \
  --copy-metadata kokoro \
  --copy-metadata misaki \
  app.py
```