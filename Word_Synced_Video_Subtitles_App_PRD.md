# PRD: Word-Synced Burned-In Video Subtitles for Offline Kokoro TTS macOS App

## 1. Product Summary

Add a video export feature that generates word-synced, styled, burned-in subtitles for videos using the app's existing offline Kokoro TTS pipeline.

The app should allow a user to:

1. Enter or paste text.
2. Generate speech using the existing local Kokoro TTS backend.
3. Align the generated voice with the original text at word level.
4. Generate styled dynamic subtitles where the currently spoken word is highlighted.
5. Burn those subtitles into a video using FFmpeg.
6. Export a final `.mp4` video containing the generated voice and embedded animated subtitles.

This feature is intended for TikTok/Reels/YouTube Shorts style videos, where each spoken word can be highlighted in sync with the generated voice.

---

## 2. Existing Project Context

The current app is a native macOS SwiftUI app using a local Python FastAPI backend for Kokoro TTS generation. The Python backend streams WAV bytes to the SwiftUI frontend. The app is designed to be fully offline and private, with the backend packaged into the macOS app bundle as a PyInstaller executable.

Relevant existing architecture:

```text
SwiftUI frontend
    ↓ HTTP POST
Python FastAPI backend
    ↓ Kokoro TTS
Generated WAV audio stream
    ↓
SwiftUI playback / export
```

The current implementation already includes:

- SwiftUI 6 frontend.
- Local Python FastAPI backend.
- Kokoro-82M TTS generation.
- Offline operation.
- Audio streaming from backend to frontend.
- PyInstaller packaging for the Python backend.
- Intel Mac compatibility.

This PRD extends the backend and export workflow to support video subtitle rendering.

---

## 3. Problem Statement

Standard `.srt` subtitles are not sufficient for the desired feature because:

- `.srt` has weak and inconsistent styling support.
- `.srt` does not reliably support per-word dynamic highlighting.
- Styling support differs between video players.
- Embedded video subtitles require deterministic rendering.

The app needs a deterministic subtitle rendering pipeline where the final `.mp4` contains the subtitles directly burned into the video frames.

---

## 4. Goals

### Primary Goals

- Generate word-level timing data for Kokoro-generated speech.
- Create styled ASS subtitle files from word timing data.
- Burn ASS subtitles into a video using FFmpeg/libass.
- Allow active word highlighting in a different color.
- Support bold, outline, shadow, font size, positioning, and subtitle grouping.
- Export a final `.mp4` video with generated voice and embedded subtitles.

### Secondary Goals

- Support preview of subtitle timing in SwiftUI using the same `words.json` timing data.
- Support both fast approximate timing and accurate forced-alignment timing.
- Keep all processing offline.
- Preserve existing streaming TTS behavior.
- Avoid breaking the existing text-to-speech workflow.

---

## 5. Non-Goals

- Do not rely on `.srt` as the main dynamic subtitle format.
- Do not require cloud APIs.
- Do not require Apple Silicon.
- Do not implement full video editing/timeline editing in this phase.
- Do not add complex multi-track timeline support.
- Do not implement manual word timing editing in the first version.

---

## 6. Recommended Technical Approach

Use this export pipeline:

```text
Input video
    +
Input text
    ↓
Generate voice.wav using Kokoro
    ↓
Generate word timings
    ↓
Create words.json
    ↓
Create subtitles.ass
    ↓
Run FFmpeg with ASS subtitle filter
    ↓
Export final.mp4
```

The internal canonical timing format should be JSON, not ASS or SRT.

ASS should be treated as a generated render artifact.

---

## 7. Output Files

For each export job, create a temporary export directory containing:

```text
export-job-uuid/
    input.mp4
    voice.wav
    words.json
    subtitles.ass
    final.mp4
    export-metadata.json
```

Only `final.mp4` needs to be shown to the user by default.

Advanced/debug mode may expose:

- `voice.wav`
- `words.json`
- `subtitles.ass`

---

## 8. Word Timing Format

Use this as the canonical internal format:

```json
{
  "text": "Hello Burak this is Kokoro",
  "sampleRate": 24000,
  "duration": 2.2,
  "words": [
    {
      "index": 0,
      "word": "Hello",
      "start": 0.0,
      "end": 0.42,
      "confidence": 1.0
    },
    {
      "index": 1,
      "word": "Burak",
      "start": 0.42,
      "end": 0.78,
      "confidence": 1.0
    }
  ]
}
```

### Field Notes

- `start` and `end` are seconds from the beginning of `voice.wav`.
- `confidence` may be `1.0` for approximate timing.
- For forced alignment, set actual confidence if available.
- Preserve punctuation where possible, but separate timing should be attached to spoken words.

---

## 9. Subtitle Style Settings

The SwiftUI frontend should allow the user to configure subtitle style.

Initial settings:

```json
{
  "fontName": "Arial",
  "fontSize": 64,
  "activeColor": "#FFFF00",
  "inactiveColor": "#FFFFFF",
  "outlineColor": "#000000",
  "shadowColor": "#000000",
  "outlineWidth": 4,
  "shadowDepth": 2,
  "boldActiveWord": false,
  "boldAllText": true,
  "alignment": "bottomCenter",
  "bottomMargin": 130,
  "maxWordsPerLine": 7,
  "maxGroupDuration": 3.5,
  "videoWidth": 1920,
  "videoHeight": 1080
}
```

### Required Presets

Add at least these presets:

1. `Clean White`
2. `TikTok Yellow`
3. `Bold Meme`
4. `Minimal Lower Third`

---

## 10. ASS Subtitle Generation

ASS/SSA subtitles should be used for FFmpeg rendering because ASS supports rich styling, karaoke timing, colors, outlines, shadows, font configuration, and positioning.

### ASS Color Format

ASS color format is:

```text
&H00BBGGRR
```

Example conversions:

```text
#FFFFFF -> &H00FFFFFF
#FFFF00 -> &H0000FFFF
#000000 -> &H00000000
#FF0000 -> &H000000FF
#00FF00 -> &H0000FF00
#0000FF -> &H00FF0000
```

Implement a utility function:

```python
def hex_to_ass_color(hex_color: str) -> str:
    """Convert #RRGGBB to ASS &H00BBGGRR format."""
```

---

## 11. Karaoke Highlight Mode

The default implementation should use ASS karaoke tags.

Example:

```ass
{\k42}Hello {\k36}Burak {\k28}this {\k20}is {\k94}Kokoro
```

`\k` duration is in centiseconds.

Example:

```text
\k42 = 0.42 seconds
```

This is the recommended first implementation because it is compact, reliable, and easy to render with FFmpeg/libass.

---

## 12. Optional Bold Active Word Mode

ASS karaoke mode can highlight the active word, but it does not naturally make only the active word bold while all other words remain regular.

For true active-word-only bolding, generate per-word dialogue events.

Example:

```ass
Dialogue: 0,0:00:00.00,0:00:00.42,Karaoke,,0,0,0,,{\b1\c&H0000FFFF&}Hello{\b0\c&H00FFFFFF&} Burak this is Kokoro
Dialogue: 0,0:00:00.42,0:00:00.78,Karaoke,,0,0,0,,Hello {\b1\c&H0000FFFF&}Burak{\b0\c&H00FFFFFF&} this is Kokoro
```

This mode creates larger `.ass` files and should be optional.

### Recommendation

Version 1 should implement:

- Karaoke color highlighting with `\k` tags.
- Bold all subtitle text if desired.

Version 2 may implement:

- Active-word-only bold rendering.

---

## 13. Subtitle Grouping

Do not render an entire paragraph as one subtitle line.

Group words into readable blocks.

Default grouping rules:

- Maximum 7 words per subtitle group.
- Maximum 3.5 seconds per subtitle group.
- Maximum 2 visual lines.
- Prefer breaking at punctuation.
- Prefer keeping short phrases together.

### Grouping Function

Implement:

```python
def group_words(
    words: list[dict],
    max_words_per_line: int = 7,
    max_duration: float = 3.5
) -> list[list[dict]]:
    """Group aligned words into subtitle dialogue blocks."""
```

---

## 14. ASS Generation Example

Implement a Python module named:

```text
subtitle_renderer.py
```

Example functions:

```python
def ass_time(seconds: float) -> str:
    """Convert seconds to ASS timestamp H:MM:SS.cc."""


def hex_to_ass_color(hex_color: str) -> str:
    """Convert #RRGGBB to ASS &H00BBGGRR."""


def group_words(words: list[dict], max_words_per_line: int, max_duration: float) -> list[list[dict]]:
    """Group words for readable subtitle blocks."""


def generate_karaoke_ass(
    words: list[dict],
    output_path: str,
    style: dict
) -> None:
    """Generate ASS karaoke subtitle file from word timings."""
```

Example ASS output:

```ass
[Script Info]
Title: Kokoro Word Sync
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080
WrapStyle: 2
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Karaoke,Arial,64,&H0000FFFF,&H00FFFFFF,&H00000000,&H80000000,1,0,0,0,100,100,0,0,1,4,2,2,100,100,130,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:00:02.20,Karaoke,,0,0,0,,{\k42}Hello {\k36}Burak {\k28}this {\k20}is {\k94}Kokoro
```

---

## 15. Word Timing Generation

Support two timing modes.

### 15.1 Fast Approximate Mode

This mode should be quick and offline.

Approach:

1. Generate the full sentence or subtitle group audio using Kokoro.
2. Measure total duration from audio sample count.
3. Split duration across words using weighted estimation.
4. Weight words by approximate phoneme length or character length.

Basic approximation:

```python
def approximate_word_timings(text: str, audio_duration: float) -> list[dict]:
    words = tokenize_words(text)
    weights = [max(1, len(word)) for word in words]
    total_weight = sum(weights)

    current = 0.0
    result = []

    for index, word in enumerate(words):
        duration = audio_duration * weights[index] / total_weight
        result.append({
            "index": index,
            "word": word,
            "start": current,
            "end": current + duration,
            "confidence": 0.4
        })
        current += duration

    return result
```

This mode is acceptable for quick preview but will not be frame-perfect.

### 15.2 Accurate Forced Alignment Mode

This mode should be used for final exports.

Approach:

```text
voice.wav + original transcript
    ↓
forced aligner
    ↓
words.json with exact word start/end times
```

The implementation should use a local/offline forced alignment tool.

Potential options:

- Montreal Forced Aligner.
- WhisperX.
- Whisper timestamp-based alignment.
- Any local forced alignment backend that can return word start/end timestamps.

For the first production-quality implementation, prefer a local forced alignment backend that works reliably on Intel macOS.

### Requirements for Forced Alignment Adapter

Create an abstraction:

```python
class WordAligner:
    def align(self, audio_path: str, transcript: str) -> list[dict]:
        raise NotImplementedError
```

Implement at least:

```python
class ApproximateWordAligner(WordAligner):
    pass
```

Later add:

```python
class ForcedWordAligner(WordAligner):
    pass
```

---

## 16. FFmpeg Integration

The backend should call FFmpeg as a subprocess.

### Basic Burn-In Command

```bash
ffmpeg -y \
  -i input.mp4 \
  -i voice.wav \
  -vf "ass=subtitles.ass" \
  -map 0:v:0 \
  -map 1:a:0 \
  -c:v libx264 \
  -crf 18 \
  -preset medium \
  -c:a aac \
  -b:a 192k \
  -shortest \
  final.mp4
```

### Notes

- `-vf "ass=subtitles.ass"` burns the ASS subtitles into the video frames.
- `-map 0:v:0` uses the input video's video stream.
- `-map 1:a:0` uses the generated Kokoro audio.
- `-shortest` stops output at the shorter stream.
- Use `-y` to overwrite output in temporary directories.

---

## 17. Handling Paths for FFmpeg ASS Filter

FFmpeg subtitle filters can be sensitive to paths with spaces and special characters.

Implementation requirements:

- Prefer creating temporary export folders with safe paths.
- Escape paths correctly.
- Use absolute paths.
- Test with paths containing spaces.

Suggested internal temporary path format:

```text
~/Library/Application Support/SpeechApp/Exports/{uuid}/
```

Avoid special characters inside generated filenames:

```text
input.mp4
voice.wav
subtitles.ass
final.mp4
```

---

## 18. Audio Modes

Support these audio export modes.

### Mode A: Replace Original Audio

Default.

```text
final video audio = generated Kokoro voice only
```

FFmpeg:

```bash
-map 1:a:0
```

### Mode B: Mix Original Audio with Generated Voice

Optional.

```bash
ffmpeg -y \
  -i input.mp4 \
  -i voice.wav \
  -filter_complex "[0:a]volume=0.25[a0];[1:a]volume=1.0[a1];[a0][a1]amix=inputs=2:duration=shortest[aout]" \
  -vf "ass=subtitles.ass" \
  -map 0:v:0 \
  -map "[aout]" \
  -c:v libx264 \
  -crf 18 \
  -preset medium \
  -c:a aac \
  -b:a 192k \
  -shortest \
  final.mp4
```

Mode B can be added after Mode A works.

---

## 19. Backend API Design

Add endpoint:

```http
POST /export/video-with-word-subtitles
```

### Request Body

```json
{
  "videoPath": "/absolute/path/input.mp4",
  "text": "Hello Burak this is Kokoro",
  "voice": "af_heart",
  "timingMode": "approximate",
  "audioMode": "replace",
  "style": {
    "fontName": "Arial",
    "fontSize": 64,
    "activeColor": "#FFFF00",
    "inactiveColor": "#FFFFFF",
    "outlineColor": "#000000",
    "shadowColor": "#000000",
    "outlineWidth": 4,
    "shadowDepth": 2,
    "boldAllText": true,
    "boldActiveWord": false,
    "bottomMargin": 130,
    "maxWordsPerLine": 7,
    "maxGroupDuration": 3.5,
    "videoWidth": 1920,
    "videoHeight": 1080
  }
}
```

### Response Body

```json
{
  "jobId": "uuid",
  "outputVideoPath": "/absolute/path/final.mp4",
  "audioPath": "/absolute/path/voice.wav",
  "wordsPath": "/absolute/path/words.json",
  "assPath": "/absolute/path/subtitles.ass",
  "duration": 2.2
}
```

---

## 20. Export Job Progress

Video export can take time. Add job progress reporting.

Potential statuses:

```text
queued
preparing
synthesizing_audio
aligning_words
generating_subtitles
rendering_video
completed
failed
```

Backend can expose:

```http
GET /export/jobs/{jobId}
```

Response:

```json
{
  "jobId": "uuid",
  "status": "rendering_video",
  "progress": 0.72,
  "message": "Burning subtitles into video...",
  "outputVideoPath": null,
  "error": null
}
```

Initial version may implement synchronous export first, then async job polling later.

---

## 21. SwiftUI Frontend Requirements

Add a new export panel or screen.

### UI Inputs

- Video file picker.
- Text input area.
- Voice picker.
- Subtitle style preset picker.
- Font size control.
- Active word color picker.
- Inactive word color picker.
- Outline width slider.
- Bottom margin slider.
- Max words per line picker.
- Timing mode picker:
  - Fast approximate
  - Accurate alignment, disabled until implemented if necessary.
- Audio mode picker:
  - Replace original audio
  - Mix with original audio, optional later.

### UI Actions

- Generate Preview Audio.
- Export Video.
- Reveal Export in Finder.

### UI Status

Show export progress stages:

```text
Generating voice...
Aligning words...
Building subtitles...
Rendering video...
Done.
```

---

## 22. Swift Data Models

Example Swift models:

```swift
struct TimedWord: Codable, Identifiable {
    var id: Int { index }
    let index: Int
    let word: String
    let start: TimeInterval
    let end: TimeInterval
    let confidence: Double?
}

struct WordTimingResult: Codable {
    let text: String
    let sampleRate: Int
    let duration: TimeInterval
    let words: [TimedWord]
}

struct SubtitleStyle: Codable {
    let fontName: String
    let fontSize: Int
    let activeColor: String
    let inactiveColor: String
    let outlineColor: String
    let shadowColor: String
    let outlineWidth: Int
    let shadowDepth: Int
    let boldAllText: Bool
    let boldActiveWord: Bool
    let bottomMargin: Int
    let maxWordsPerLine: Int
    let maxGroupDuration: Double
    let videoWidth: Int
    let videoHeight: Int
}
```

---

## 23. Python Module Structure

Suggested backend module layout:

```text
backend/
    app.py
    tts_engine.py
    alignment/
        __init__.py
        base.py
        approximate.py
        forced.py
    subtitles/
        __init__.py
        ass_renderer.py
        colors.py
        grouping.py
    video/
        __init__.py
        ffmpeg_runner.py
        export_job.py
```

---

## 24. Implementation Tasks

### Phase 1: ASS Subtitle Rendering

- [x] Add `subtitles/colors.py` with `hex_to_ass_color`.
- [x] Add `subtitles/grouping.py` with word grouping logic.
- [x] Add `subtitles/ass_renderer.py`.
- [x] Generate valid `.ass` file from mock word timings.
- [ ] Test `.ass` rendering manually with FFmpeg.

### Phase 2: Approximate Word Timing

- [x] Add word tokenizer.
- [x] Add approximate word timing generation.
- [x] Generate `words.json`.
- [x] Verify total word timing duration matches generated audio duration.
- [ ] Test with short, medium, and long text.

### Phase 3: FFmpeg Export

- [x] Add FFmpeg availability check.
- [x] Add FFmpeg/libass diagnostic check.
- [x] Add `video/ffmpeg_runner.py`.
- [x] Add replace-audio export command.
- [x] Add safe temp export directory creation.
- [x] Export final `.mp4` with burned-in subtitles.
- [x] Handle FFmpeg errors and logs.

### Phase 4: Backend Endpoint

- [ ] Add `/export/video-with-word-subtitles` endpoint.
- [ ] Validate request payload.
- [ ] Generate voice WAV.
- [ ] Generate word timings.
- [ ] Generate ASS subtitles.
- [ ] Run FFmpeg.
- [ ] Return output paths.

### Phase 5: SwiftUI Integration

- [ ] Add bundled tool installer for `ffmpeg` and `ffprobe`.
- [x] Add central Swift `FFmpegRunner`.
- [x] Add FFmpeg diagnostics screen or developer diagnostic log.
- [x] Add video picker.
- [x] Add subtitle style controls.
- [x] Add timing mode picker.
- [x] Add export button.
- [x] Display progress messages.
- [x] Reveal output in Finder.

### Phase 6: Accurate Alignment

- [x] Create `WordAligner` interface.
- [x] Keep approximate aligner as fallback.
- [ ] Research and integrate offline forced alignment backend.
- [ ] Add accurate alignment mode.
- [ ] Compare accuracy vs approximate mode.

### Phase 7: Optional Enhancements

- [ ] Add original audio mixing mode.
- [x] Add active-word-only bold mode.
- [ ] Add more subtitle presets.
- [x] Add live SwiftUI karaoke preview.
- [ ] Add export of `.ass`, `.vtt`, and `words.json` as optional artifacts.

---

## 25. Acceptance Criteria

### MVP Acceptance Criteria

- User can select an input video.
- User can enter text.
- App generates Kokoro voice audio.
- App creates word timing JSON using approximate mode.
- App creates a valid ASS subtitle file.
- App burns subtitles into video using FFmpeg.
- Final `.mp4` contains:
  - Original video stream.
  - Generated Kokoro voice audio.
  - Burned-in word-highlight subtitles.
- Export works fully offline.
- Exported file can be played in QuickTime/VLC without requiring subtitle sidecar files.

### Quality Criteria

- Subtitle text should be readable.
- Words should highlight in approximate sync with audio.
- No subtitle line should contain an entire long paragraph.
- FFmpeg failures should be shown clearly to the user.
- Paths with spaces should work.
- Temporary files should not pollute project directories.

---

## 26. Testing Plan

### Unit Tests

- `hex_to_ass_color("#FFFFFF") == "&H00FFFFFF"`
- `hex_to_ass_color("#FFFF00") == "&H0000FFFF"`
- `ass_time(0.42) == "0:00:00.42"`
- `group_words` respects max word count.
- `group_words` respects max duration.
- ASS output contains required sections:
  - `[Script Info]`
  - `[V4+ Styles]`
  - `[Events]`

### Integration Tests

- Generate video from 5-word input.
- Generate video from 50-word input.
- Generate video with punctuation.
- Generate video with paths containing spaces.
- Export using different font sizes.
- Export with different colors.

### Manual Tests

- Open final video in QuickTime.
- Open final video in VLC.
- Verify subtitles are burned into pixels.
- Verify active word highlighting is visible.
- Verify audio and subtitles roughly match.

---

## 27. Dependencies

### Required

- Existing Kokoro TTS backend.
- Bundled FFmpeg binary with libass ASS subtitle filter support.
- Bundled FFprobe binary for media diagnostics.
- Python FastAPI backend.
- SwiftUI frontend.

### Python Additions

Prefer standard library for MVP where possible:

```text
subprocess
pathlib
json
uuid
tempfile
re
```

No new Python dependency is required for approximate timing.

Forced alignment may require additional dependencies later.

---

## 28. FFmpeg Packaging Notes

The app should package FFmpeg using the same general resource/subprocess pattern already used by the app for the bundled PyInstaller TTS backend. The FFmpeg binary should be included in Swift Package resources, copied to a writable tools directory on first launch, marked executable, and then launched using Swift `Process`.

### 28.1 Recommended Packaging Strategy

Use this approach for the production app:

```text
Bundled SwiftPM resource
    ↓
Copy to Application Support tools directory
    ↓
chmod 755
    ↓
Run copied binary through Swift Process
```

Do not rely only on Homebrew for the main user flow. Homebrew detection may remain as a developer fallback, but bundled FFmpeg provides the best user experience.

### 28.2 SwiftPM Resource Layout

Recommended package layout:

```text
speechapp/
├─ Package.swift
└─ Sources/
   └─ speechapp/
      ├─ App/
      ├─ Resources/
      │  ├─ tts_backend
      │  ├─ ffmpeg
      │  └─ ffprobe
      └─ ...
```

`ffprobe` should be bundled alongside `ffmpeg` because it is useful for reading video duration, resolution, stream layout, codec info, and whether the input video already contains an audio track.

### 28.3 Package.swift Resource Rule

Use `.copy`, not `.process`, so SwiftPM preserves the binaries as-is:

```swift
.target(
    name: "speechapp",
    resources: [
        .copy("Resources")
    ]
)
```

The coding agent should verify that `Bundle.module.url(forResource:withExtension:subdirectory:)` can resolve both `ffmpeg` and `ffprobe` after release builds.

### 28.4 Runtime Install Location

On launch or before first video export, copy tools to:

```text
~/Library/Application Support/speechapp/Tools/ffmpeg
~/Library/Application Support/speechapp/Tools/ffprobe
```

Create the directory if needed. After copying, set POSIX permissions to `755`.

Rationale:

- Resource permissions can be unreliable after packaging.
- Running tools from a writable app support directory is easier to diagnose.
- Future updates can replace tools by version.
- The app bundle remains read-only after installation.

### 28.5 Swift Runtime Installer

Add a Swift utility similar to this:

```swift
import Foundation

enum ToolInstallError: Error {
    case bundledToolNotFound(String)
}

struct BundledToolInstaller {
    static let appFolderName = "speechapp"

    static func installedToolURL(named toolName: String) throws -> URL {
        guard let sourceURL = Bundle.module.url(
            forResource: toolName,
            withExtension: nil,
            subdirectory: "Resources"
        ) else {
            throw ToolInstallError.bundledToolNotFound(toolName)
        }

        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let toolsDir = appSupport
            .appendingPathComponent(appFolderName, isDirectory: true)
            .appendingPathComponent("Tools", isDirectory: true)

        try FileManager.default.createDirectory(
            at: toolsDir,
            withIntermediateDirectories: true
        )

        let destinationURL = toolsDir.appendingPathComponent(toolName)

        if !FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: destinationURL.path
        )

        return destinationURL
    }

    static func ffmpegURL() throws -> URL {
        try installedToolURL(named: "ffmpeg")
    }

    static func ffprobeURL() throws -> URL {
        try installedToolURL(named: "ffprobe")
    }
}
```

### 28.6 Swift FFmpeg Runner

Add a central runner instead of scattering `Process` calls throughout the app:

```swift
import Foundation

struct FFmpegRunner {
    static func run(arguments: [String]) async throws -> String {
        let ffmpegURL = try BundledToolInstaller.ffmpegURL()

        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = ffmpegURL
            process.arguments = arguments

            let outputPipe = Pipe()
            let errorPipe = Pipe()

            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            let output = String(data: outputData, encoding: .utf8) ?? ""
            let error = String(data: errorData, encoding: .utf8) ?? ""

            guard process.terminationStatus == 0 else {
                throw NSError(
                    domain: "FFmpegRunner",
                    code: Int(process.terminationStatus),
                    userInfo: [
                        NSLocalizedDescriptionKey: error.isEmpty ? output : error
                    ]
                )
            }

            return output + error
        }.value
    }
}
```

For later progress UI, replace `waitUntilExit()` with asynchronous stderr reading and parse FFmpeg progress logs. MVP may use stage-based progress only.

### 28.7 FFmpeg Diagnostics

Before enabling export, run diagnostics:

```bash
ffmpeg -version
ffmpeg -filters
ffmpeg -encoders
ffprobe -version
```

The app must verify:

- FFmpeg executable launches successfully.
- FFprobe executable launches successfully.
- FFmpeg has the `ass` video filter.
- FFmpeg has at least one usable H.264 encoder.
- FFmpeg has AAC audio encoding support.

The `ass` filter is required for burned-in ASS subtitles. If missing, show a clear error: `Bundled FFmpeg does not include libass subtitle rendering support.`

### 28.8 Encoder Strategy

Support two encoding profiles:

```text
Quality profile:
    -c:v libx264 -crf 18 -preset medium

Fast macOS profile:
    -c:v h264_videotoolbox -b:v 6000k
```

For MVP, default to the most reliable encoder available in the bundled FFmpeg build. If the LGPL-friendly build does not include `libx264`, use `h264_videotoolbox` or another non-GPL-compatible encoder.

### 28.9 FFmpeg Path Escaping for ASS Filter

The ASS filter path must handle spaces and special characters. Prefer safe generated export directories and simple filenames. Still add a helper:

```swift
func ffmpegFilterPath(_ path: String) -> String {
    path
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: ":", with: "\\:")
        .replacingOccurrences(of: "'", with: "\\'")
}
```

Use:

```swift
let assPath = ffmpegFilterPath(subtitleASS.path)
let filter = "ass='\(assPath)'"
```

The test suite must include paths with spaces.


### 28.13 FFmpeg Packaging Acceptance Criteria

- App release build contains `ffmpeg` and `ffprobe` resources.
- On first export, both tools are copied to Application Support.
- Copied tools have executable permissions.
- App can run `ffmpeg -version` and `ffprobe -version`.
- App detects whether the `ass` filter is available.
- App can burn a generated `.ass` file into a test video.
- Export works when the input video path contains spaces.
- Export errors include FFmpeg stderr.
- Licensing notes are included before public distribution.

---

## 29. Risks

### Risk: Approximate Timing Is Not Accurate Enough

Mitigation:

- Label it as `Fast Approximate`.
- Add forced alignment mode later.
- Keep `words.json` format stable so alignment backend can be swapped.

### Risk: FFmpeg Path Issues

Mitigation:

- Use safe temporary file names.
- Use absolute paths.
- Add FFmpeg diagnostic check.
- Capture stderr logs.

### Risk: Font Rendering Differences

Mitigation:

- Use common fonts first.
- Allow font selection later.
- Use bundled fonts only if legally allowed.

### Risk: Intel Mac Performance

Mitigation:

- Start with approximate timing.
- Use FFmpeg presets.
- Show progress.
- Allow lower quality export option.

---

## 30. Future Improvements

- Accurate forced alignment.
- Per-word bounce/scale animation.
- Background caption box.
- Emoji support.
- Multiple caption templates.
- Vertical video presets: 1080x1920.
- Auto-resize video for Shorts/Reels.
- Burn subtitles over generated image/video backgrounds.
- Export sidecar `.ass`, `.vtt`, `.srt`, and `words.json`.
- Live timeline preview.
- Manual timing correction UI.

---

## 31. Recommended MVP Scope

Build this first:

```text
Input video + text
↓
Generate Kokoro voice.wav
↓
Approximate word timings
↓
Generate ASS karaoke subtitles
↓
FFmpeg burn-in
↓
Export final.mp4
```

Do not start with forced alignment unless the approximate pipeline is already working.

The key is to first prove the full video export path end-to-end. Once the pipeline works, replace approximate timing with accurate forced alignment behind the same `WordAligner` interface.
