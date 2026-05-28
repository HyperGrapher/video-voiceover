# AGENTS.md

## App Overview

This is a native macOS SwiftUI app evolving from offline Kokoro text-to-speech into a video/audio and subtitle placement, arrangement app for easier social media content creation.

- The Swift app launches the bundled Python FastAPI backend from `Sources/speechapp/Resources/tts_backend`.
- `app.py` is source only. Editing it does not update the bundled executable until the user repackages the backend.
- Live TTS uses raw little-endian 16-bit mono PCM at 24 kHz (`pcm_s16le`) from `/tts`.
- Swift streams PCM through `AVAudioEngine`/`AVAudioPlayerNode`; do not go back to partial WAV snapshots or one-shot `AVAudioPlayer` for live streaming.
- Saved speech recordings are AAC `.m4a` for macOS/iOS compatibility; existing `.wav` files should remain visible/playable.
- Video work is currently an editor shell only: import, preview, transport controls, timeline, and scrubbing. No FFmpeg export, subtitle rendering, or alignment has been implemented yet.

## Standing Instructions

- Log only durable, meaningful project changes here. Do not add noisy step-by-step diary entries.
- Do not run PyInstaller or Python packaging by default. It is slow, and the user will package manually.
- Normal verification is `swift build`; keep it warning-free.
- FFmpeg is installed locally for development but should not be packaged or required in the current video-shell phase.
- Inspect existing code before trusting previous implementation choices.

## Important Implementation Notes

### Audio

- Backend `/tts` streams raw PCM bytes with headers describing `pcm_s16le`, 24 kHz, mono.
- Backend `/tts-file` returns a complete WAV, but the Swift app saves generated audio as `.m4a`.
- Completed streams are saved; canceled streams are not saved.

### Video Import And Preview

- Imported or dropped videos are copied into `~/Library/Application Support/speechapp/VideoImports` before AVFoundation loads them. This gives the app a stable local file path and avoids Finder/drop URL lifetime and permission problems.
- The app uses `startAccessingSecurityScopedResource()` while copying selected/dropped files.
- Reject zero-duration/invalid assets before installing them into the player.
- Do not use SwiftUI `VideoPlayer` for the preview on this project. Crash reports showed SIGABRT inside Apple’s `_AVKit_SwiftUI` framework during import. The current fix is a plain `NSViewRepresentable` wrapper around `AVPlayerView`, which avoids that SwiftUI wrapper path while still using `AVPlayer`.
- The normal macOS title bar is intentionally restored. Hidden-titlebar mode caused the video preview to cover the title/control area and made import controls appear missing.

## Current Milestones

- TTS screen: live streaming, cancel, save, play/delete saved recordings.
- Video screen: import/drop video, preview with `AVPlayerView`, transport controls, three placeholder tracks, red draggable/clickable playhead for seeking.
- Next likely work: stabilize video preview UX, then add PRD-driven subtitle/export pipeline using local FFmpeg without packaging it yet.
