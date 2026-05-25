# AGENTS.md

## App Overview

This project is a native macOS SwiftUI app that streams offline text-to-speech audio from a local Python FastAPI backend using Kokoro. The Swift app launches the bundled backend executable from `Sources/speechapp/Resources/tts_backend`, sends text and voice selections to `http://localhost:8000/tts`, and plays returned audio progressively.

The intended streaming protocol is raw little-endian 16-bit mono PCM at 24 kHz (`pcm_s16le`), not repeated WAV files. Swift converts incoming PCM into `AVAudioPCMBuffer` instances and schedules them on `AVAudioEngine`/`AVAudioPlayerNode`.

## Standing Instructions For Future Agents

- Log meaningful project changes in this file before finishing work.
- Do not run the Python packaging command or PyInstaller by default. Packaging takes around 5 minutes and the user will run it manually.
- For normal verification, run the macOS Swift build and make sure it completes without warnings.
- Do not trust earlier implementation choices just because they exist. Inspect the code and keep the streaming/audio contract explicit.
- Keep the backend source `app.py` and bundled backend executable in mind as separate artifacts. Editing `app.py` does not update `Sources/speechapp/Resources/tts_backend` until the user packages it.

## Change Log

### 2026-05-25

- Replaced the frontend's one-shot `AVAudioPlayer` snapshot approach with continuous PCM scheduling through `AVAudioEngine` and `AVAudioPlayerNode`.
- Renamed the UI action from `Stream Text` to `Stream Sound`.
- Changed the backend streaming contract in `app.py` from repeated WAV chunks to raw `pcm_s16le` bytes with explicit response headers.
- Added backend text chunking so long inputs are split into smaller Kokoro synthesis spans before streaming. This should reduce time-to-first-audio for long sentences.
- Added a short initial audio cushion in Swift before playback starts to reduce early buffer underruns and audible stutter.
- Updated `Package.swift` to exclude non-resource target files that SwiftPM previously warned about.
- Added this `AGENTS.md` file with app context, workflow constraints, and change logging expectations.
- Added a non-streaming `/tts-file` backend endpoint that returns a complete WAV file for save-to-disk workflows.
- Reworked the SwiftUI app into a two-pane macOS interface with a composer area and saved-audio library.
- Added saved WAV file management under Application Support, including refresh, play/pause, and delete actions.
- Added streaming cancellation so live audio can be stopped without creating or saving any file.
- Added saved-file behavior for completed streams, a fallback save path when the bundled backend does not yet expose `/tts-file`, clearer error status icons, and an open-folder button for the recordings directory.
- Excluded the extra `Resources/tts_backend-ex` file from SwiftPM target scanning so the user's alternate backend copy stays in place without build warnings.
