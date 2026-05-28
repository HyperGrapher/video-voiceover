# AGENTS.md

## App Overview

This is a native macOS SwiftUI app for private, offline voiceover and video subtitle production. The app turns text into natural-sounding AI narration with Kokoro TTS, then will align words, style animated subtitles, and burn finished subtitles into video with local FFmpeg in later milestones.

- The Swift app launches the bundled Python FastAPI backend from `Sources/speechapp/Resources/tts_backend`.
- `app.py` is source only. Editing it does not update the bundled executable until the user repackages the backend.
- Live TTS uses raw little-endian 16-bit mono PCM at 24 kHz (`pcm_s16le`) from `/tts`.
- Swift streams PCM through `AVAudioEngine`/`AVAudioPlayerNode`; do not go back to partial WAV snapshots or one-shot `AVAudioPlayer` for live streaming.
- Saved speech recordings are AAC `.m4a` for macOS/iOS compatibility; existing `.wav` files should remain visible/playable.
- The app is now project based. Project files use `.speechproj` JSON and reference imported media paths.
- Video work is currently an editor shell only: launch/recent-projects flow, create/open project, import, preview, transport controls, timeline, scrubbing, and narration modal. No FFmpeg export, subtitle rendering, or alignment has been implemented yet.

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
- Video mode reserves top spacing in `ContentView` and sizes the preview from both available width and height. Keep that constraint so the preview cannot expand upward over the editor header.

## Current Milestones

- Launch screen: create a new `.speechproj`, list previous projects, and open an editor-style project workspace.
- Narration modal: live Kokoro streaming, cancel, save, play/delete saved recordings, and project placement via `Generate and Place Into Track`.
- Video editor screen: import/drop video, preview with `AVPlayerView`, generated narration audio synced to preview playback, approximate subtitle overlay for the first placed narration, persisted subtitle style controls including Word Highlighting and timing mode, transport controls, video/audio/subtitle tracks, red draggable/clickable playhead for seeking, and Swift-side FFmpeg render/export.
- PRD section `24. Implementation Tasks` is the implementation handoff checklist. Keep it updated as work lands.
- Phase 1 ASS subtitle rendering, most of Phase 2 approximate timing, and Phase 3 FFmpeg helpers now exist in Python source for the future backend plus Swift-side app code in `ExportSupport.swift` for the current packaged app. The app does not need Python repackaging for current preview/export: Swift generates `words.json`/`subtitles.ass` from `ProjectNarration`, runs local FFmpeg, and reveals the exported MP4. Preview and export share `SubtitleStyleSettings`; ASS export uses per-active-word dialogue events when Word Highlighting is enabled and static grouped subtitle events when disabled. Tokenizers preserve punctuation attached to words, and the default Smart timing mode reserves punctuation pauses plus uses spoken-duration weights. `app.py` source `/tts-file` now generates the full text without `split_text_for_low_latency`, but the bundled backend still needs repackaging before that source change affects the app. Next likely work: test approximate timing with short/medium/long text, then research true offline forced alignment.
