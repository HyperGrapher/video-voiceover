# Video Editor PRD — Main Window, Track System & Editing Panels

**App:** SpeechApp — native macOS SwiftUI + bundled Python FastAPI (Kokoro TTS)  
**Scope:** Main window layout, video preview, multi-track timeline, clip types, overlap handling, audio mixing, inspector panel tabs, user workflow, project file extensions, and phased implementation plan.  
**Format:** Coding-agent handoff. Every section is actionable. Refer to `AGENTS.md` and `ImplementationPlan.md` for existing decisions that must not be reversed.

---

## 1. Main Window Layout

Three primary zones stacked vertically:

```
┌─────────────────────────────────────────────────────────┐
│  TOP BAR — title, transport controls, export button     │
├───────────────────────────────┬─────────────────────────┤
│                               │                         │
│   VIDEO PREVIEW (AVPlayerView)│   INSPECTOR PANEL       │
│                               │   [tab bar + content]   │
│                               │                         │
├───────────────────────────────┴─────────────────────────┤
│  TIMELINE                                               │
│  [track headers 200pt] | [scrollable track canvas →]   │
└─────────────────────────────────────────────────────────┘
```

- A **horizontal drag handle** separates the middle zone from the timeline. Min timeline height: **180 pt**. Min preview height: **160 pt**.
- A **vertical drag handle** separates preview from inspector inside the middle zone.

### 1.1 Top Bar

| Position | Contents |
|---|---|
| Left | Project name (inline-editable on double-click) + dirty-state dot |
| Centre | Go to Start · Step Back · Play/Pause (Space) · Step Forward · Go to End |
| Right | Master Volume slider + numeric readout · Export button · Spinner (export only) |

### 1.2 Video Preview

- **Implementation:** `NSViewRepresentable` wrapping `AVPlayerView`. Do **not** use SwiftUI `VideoPlayer` — see crash note in `AGENTS.md`.
- Fills left pane of middle zone. Aspect ratio always preserved. Letterboxing uses system window background (not black).
- Shows the Swift-rendered subtitle overlay at the current playhead position.
- When no video is imported: centred drag-and-drop target, label `"Drop video here or click to import"`, dark-grey background.

### 1.3 Video Size Handling

- Calculate the largest `AVPlayerView` frame that fits the available space while maintaining native aspect ratio. Recalculate on window resize and splitter drag.
- **Export** always uses the video's native resolution. No scaling unless a future preference adds it.
- Subtitle geometry is computed at preview scale for the preview and recomputed at native resolution for export.
- Wide-screen (16:9) and vertical (9:16) are both handled via letter/pillar-boxing.

---

## 2. Timeline

### 2.1 Structure

- **Track Header Column** — fixed width **200 pt**, scrolls vertically with the canvas.
- **Track Canvas** — horizontally scrollable, vertically scrollable in sync with headers.
- **Time Ruler** — fixed height **28 pt** above the canvas. Timecode format: `MM:SS.ff`. Tick density adapts to zoom.
- **Playhead** — red draggable needle spanning full track-canvas height. Always on top. Clicking the ruler moves the playhead. Dragging scrubs in real time (audio muted during drag, unmuted on release).

### 2.2 Zoom & Scroll

- Pinch-to-zoom + a zoom slider (bottom-right of timeline) for horizontal zoom.
- Vertical: standard scroll-wheel / two-finger swipe.
- `Home` key: centre playhead in visible window.
- `←` / `→` keys: move playhead one frame at a time.

### 2.3 Track Types

| Track | Type | Default count | Notes |
|---|---|---|---|
| Video | Single video clip lane | 1 (fixed) | Cannot be duplicated or deleted while video is loaded |
| Narration | TTS audio + subtitle pairs | 1 default, unlimited additional | |
| Background Music | Imported audio clips | 1 default, unlimited additional | |
| Sound FX | Short imported audio clips | 1 default, unlimited additional | |
| Subtitle Override | Manual subtitle-only lane | 0 default, user-added | |

### 2.4 Adding & Deleting Tracks

- **Add:** `+` button at the bottom of the track header column → popover with options: `Add Narration Track`, `Add Music Track`, `Add Sound FX Track`, `Add Subtitle Override Track`.
- **Delete:** Right-click on track header (or `…` hover button) → `Delete Track` → confirmation sheet:
  > *"Delete this track and all N clips on it? This cannot be undone."*
  - User must press the red `Delete Track` button to confirm.
- **Video track:** context menu omits Duplicate and Delete. Replace video via drag-and-drop onto the track or `Replace Video` menu item.
- **Reorder:** Drag track header row up/down. Blue insertion indicator shows drop target. Track order affects subtitle z-index (lower index = higher z-order in subtitle compositor).

### 2.5 Track Header Controls

Each header: **200 pt wide × 56 pt tall** (expands to 80 pt in expanded mode).

| Control | Behaviour |
|---|---|
| Colour swatch | Click → colour picker. Colour used as clip background tint on this track. |
| Track name | Single-click selects; double-click → rename. |
| **M** (Mute) | Mutes audio output. Clips remain visible. Affects both preview and export. Saved with project. |
| **S** (Solo) | Solos track; all other audio tracks auto-mute. Only one track solo at a time. Click again to un-solo. Restores prior mute states on un-solo. |
| **👁** (Hide) | Hides clips visually on canvas. Cosmetic only — does not affect audio or subtitle output. |
| Volume knob | Per-track volume 0–200 %. Shown on Narration, Music, SFX tracks only. Numeric readout. |
| **🔒** (Lock) | Locks all clips from being moved or edited. Playback unaffected. Saved with project. |
| Expand arrow | Expands row to show waveform / subtitle text preview inside clips. |

> **Note:** The Video track header has a dedicated `Mute Original Audio` toggle (mic-slash icon) and a volume knob for the original audio channel. It does not show M/S.

---

## 3. Clips

### 3.1 Video Clip

- Rounded rectangle from `00:00` to video duration.
- Thumbnail frames drawn inside at an interval calculated from zoom level (rendered offline on import).
- Cannot be moved or trimmed in Phase 1. Drag-replacing re-renders thumbnails.

### 3.2 Narration Clips

A `NarrationClip` is a composite object:

```swift
struct NarrationClip: Identifiable, Codable {
    var id: UUID
    var trackId: UUID
    var startTime: CMTime          // position on timeline
    var audioFilePath: String      // saved .m4a
    var text: String               // full narration text
    var words: [WordTiming]        // from approximate aligner
    var subtitleStyleOverride: SubtitleStyleSettings?
}
```

**Visual appearance:**

- Background: track colour at 80 % opacity.
- Left edge: solid track colour. Right edge: subtle fade-out gradient (fixed end, not trimmable).
- Waveform: white at 60 % opacity, rendered from `.m4a` via `AVAssetReader`.
- Subtitle pill: white background, track-colour text, 9 pt rounded pill at top-left, shows first ~40 chars.
- Selected: 2 pt white border, Inspector updates to Clip tab for this clip.

**Placement:**

- Created by Narration Modal (`Generate and Place Into Track`) at the current playhead position.
- If the playhead overlaps an existing clip on the target track, the new clip auto-nudges to that clip's end time — **unless the user holds `Option`**, which places at exact playhead position (intentional overlap).

**Interactions:**

- Drag horizontal to reposition. Snap to clip edges and playhead (4 pt snap zone). Hold `Option` to disable snap.
- Right-click menu: `Play Clip`, `Replace Audio` (re-opens modal pre-filled), `Edit Text Only` (updates subtitle text, no re-generation), `Delete Clip`.
- Double-click: open Clip Inspector in right panel.

### 3.3 Music & Sound FX Clips

- Source: drag-and-drop from Finder, or `+` inside a Music/SFX track header, onto canvas.
- Files copied to `~/Library/Application Support/speechapp/AudioImports` (same pattern as `VideoImports`).
- Waveform rendered on clip background.
- **Trim:** drag left/right edges.
- **Fade:** drag triangle handle at top-left (fade-in) or top-right (fade-out) of clip.
- Music default volume: **70 %**. SFX default volume: **100 %**.
- Right-click: `Rename Clip`, `Trim to Playhead`, `Remove Fades`, `Delete Clip`.

```swift
struct MediaClip: Identifiable, Codable {
    var id: UUID
    var trackId: UUID
    var startTime: CMTime
    var duration: CMTime           // trimmable
    var audioFilePath: String
    var volume: Float              // 0.0–2.0
    var fadeInDuration: Double     // seconds
    var fadeOutDuration: Double    // seconds
    var loop: Bool
}
```

### 3.4 Subtitle Override Clips

- Pure text clip, no audio. Contains a subtitle string and optional style overrides that supersede the project-level style for their time range.
- Created via `+` inside a Subtitle Override track → small popover text editor.
- Default duration: **3 seconds**. Extend by dragging right edge.
- Right-click: `Edit Text`, `Clear Style Overrides`, `Delete Clip`.

### 3.5 Overlap Handling

| Track type | Overlap policy |
|---|---|
| Video | Single-clip lane. New video replaces entirely. No overlaps. |
| Narration | Allowed. Visually flagged. See detail below. |
| Music / SFX | Allowed. Audio mixed additively. |
| Subtitle Override | Allowed. Topmost track's subtitle wins. Yellow warning shown. |

**Narration overlap detail:**

1. Yellow warning stripe painted on both overlapping clip edges, labelled `"Overlap"`.
2. Audio of both clips plays simultaneously (mixed). Subtitle layer shows the clip with the earlier start time.
3. `"Resolve Overlap"` appears in right-click context menu:
   - `"Push after earlier clip"` — auto-nudge newer clip to start immediately after the earlier clip.
   - `"Move to new track"` — creates a new Narration track and moves the clip there.
4. Timeline toolbar shows an orange badge `"N overlaps"` whenever any overlaps exist on any Narration track.

---

## 4. Video's Original Audio

- The imported video's original audio is always preserved in the source file (non-destructive).
- **Video track header controls:**
  - `Mute Original Audio` toggle (mic-slash icon). **Default: unmuted.**
  - Volume knob: 0–200 %, default **100 %**.
- Mute state and volume are saved in the project file.
- Muted original audio is excluded from both preview and export.

**Typical workflow:** Import talking-head video → mute original audio → add Narration clips → export. Result: narration + optional music, no original voice.

---

## 5. Adding Background Music & Sound Effects

### 5.1 Import Methods

- **Drag-and-drop** an audio file (MP3, AAC, M4A, WAV, AIFF) onto a Music or SFX track lane.
- **Click `+`** on the right side of a Music or SFX track header → `NSOpenPanel` filtered to audio types.
- Files are copied to `~/Library/Application Support/speechapp/AudioImports`. Use `startAccessingSecurityScopedResource()` during copy (same as video import).

### 5.2 Music Clip Behaviour

- Plays from its start to its end (or video end, whichever is first).
- Multiple clips on the same track overlap — audio mixed additively.
- **Loop checkbox** in Clip Inspector: loops the clip until its right-edge timeline position.
- Per-clip fade-in / fade-out via drag handles.
- Per-clip volume independent of track-level volume.

### 5.3 Sound FX Clip Behaviour

- Same model as Music. Default volume **100 %**.
- No loop checkbox (one-shot intent).
- Trim by dragging clip edges.

---

## 6. User Workflow — Generating Narration

1. Position playhead at desired start time.
2. Click mic `+` button on a Narration track **or** use the top-bar `Add Narration` button (auto-selects first Narration track).
3. Narration Modal opens. Enter text, select voice, adjust speed.
4. `Preview` → streams TTS via `/tts` PCM to `AVAudioEngine` (existing behaviour).
5. `Generate and Place Into Track` → calls `/tts-file`, saves `.m4a`, runs approximate word aligner, creates `NarrationClip` at playhead position on selected track.
6. Modal closes. New clip appears on timeline. Inspector switches to Clip tab for the new clip.
7. Repeat from step 1. No limit on number of clips or tracks.

> **Auto-nudge rule:** If playhead overlaps an existing clip on the target track, the new clip starts at that clip's `endTime`. Hold `Option` to override and place at exact playhead position.

---

## 7. Playback & Preview Composition

### Audio Engine

All un-muted audio tracks are mixed into a live `AVAudioEngine` graph:

- **Video audio:** `AVPlayerNode` fed by the video's `AVAsset` audio track.
- **Narration clips:** `AVAudioPlayerNode` per clip, scheduled at the correct timeline offset.
- **Music/SFX clips:** `AVAudioPlayerNode` per clip with per-clip volume via `AVAudioMixerNode`.

The **`AVPlayerView` is the master clock.** All audio nodes sync to `AVPlayer`'s clock. Seeking calls `seekToTime` on the player and reschedules all audio nodes.

### Subtitle Rendering

A `CADisplayLink` callback reads the current player time, finds the active word event in the active Narration clips, and updates the subtitle overlay `NSView`. Multi-track: subtitle from the lowest-index active Narration track wins when clips overlap.

### Scrubbing

During playhead drag: mute all audio. On drag-end: reschedule and unmute.

---

## 8. Inspector Panel — Tab Bar & Contents

The right pane of the middle zone. Tab bar at the top: 32×32 pt icon buttons with small labels.

```
[ 🎬 Clip ] [ 💬 Subtitles ] [ 🔊 Audio Mix ] [ 🎨 Appearance ] [ ⚙️ Export ]
```

Selected tab highlighted with system accent colour.

---

### 8.1 Clip Tab 🎬

Shows clip-specific controls when a clip is selected. Shows `"No selection"` placeholder otherwise.

**All clip types:**

- Clip name (editable text field)
- Start time (timecode input — moves clip on timeline)
- Duration (read-only for Narration; editable for Music/SFX/Subtitle Override)
- Track assignment picker (lists compatible tracks; moving reassigns clip)

**Narration clips additionally:**

- Full narration text (read-only `TextEditor`)
- `Edit Text & Regenerate` button → opens Narration Modal pre-filled
- `Replace Audio File…` button → `NSOpenPanel` to swap `.m4a`
- Word timing table: columns `Word`, `Start (s)`, `Duration (s)` — rows are editable for fine-tuning

**Music/SFX clips additionally:**

- Fade In duration (seconds, numeric field)
- Fade Out duration (seconds, numeric field)
- Loop checkbox
- Clip Volume (% slider + numeric)

**Subtitle Override clips additionally:**

- Subtitle text area
- Per-clip style overrides: font size, primary colour, position Y offset

---

### 8.2 Subtitles Tab 💬

Project-wide subtitle settings applied to all Narration clips unless overridden per-clip.

| Control | Details |
|---|---|
| Timing Mode | Picker: `Smart` (approximate) / `Manual` (word timing table) / `Off` |
| Word Highlighting | Toggle |
| Timing Offset | Slider −500 ms to +500 ms, 10 ms steps |
| Subtitle Position | Picker: `Bottom` / `Top` / `Custom` (Y offset %) |
| Max words per event | Stepper 1–8, default 4 |
| Line break mode | `Fit to line-length` / `Fixed word count` |
| Preview overlay toggle | Show/hide subtitles in preview only (no export effect) |

---

### 8.3 Audio Mix Tab 🔊

Mixer board view: one vertical channel strip per audio-bearing track + Master strip at right.

Each strip:

- Track colour indicator
- Track name (truncated)
- Vertical volume fader (0–200 %)
- Numeric readout
- **M** mute and **S** solo buttons

Master strip:

- Output volume fader (0–200 %)
- Peak meter (cosmetic, updated via lightweight timer — not frame-accurate)

> Values here are identical to track-header values. Editing either updates both.

---

### 8.4 Appearance Tab 🎨

| Control | Details |
|---|---|
| Font family | System font picker |
| Font size | Slider 12–96 pt (preview scale; export recomputes for native resolution) |
| Primary colour | Colour well (active word highlight) |
| Secondary colour | Colour well (inactive words) |
| Background pill | Toggle + colour well + opacity slider |
| Drop shadow | Toggle + colour well + blur radius slider |
| Presets | Buttons: `Clean White`, `TikTok Yellow`, `Bold Meme`, `Minimal Lower Third`, `Dark Pill` — overwrite all current settings |
| Live mini-preview | Rendered subtitle line at top of tab, updates in real time |

### 8.4.1 Required Subtitle Presets

Each preset must update project-level `SubtitleStyleSettings` and immediately refresh preview/export output. Presets are non-destructive until the project is saved.

| Preset | Intent | Defaults |
|---|---|---|
| `Clean White` | General readable captions | White text, yellow active word, black outline, no pill |
| `TikTok Yellow` | Short-form karaoke style | White inactive text, bright yellow active word, bold, strong outline |
| `Bold Meme` | High-impact meme captions | Large white uppercase-style look, thick black outline, low bottom margin |
| `Minimal Lower Third` | Quiet professional lower caption | Smaller white text, subtle outline/shadow, lower-third placement |
| `Dark Pill` | Readability over busy footage | White text inside semi-transparent dark rounded pill |

---

### 8.5 Export Tab ⚙️

| Control | Details |
|---|---|
| Output directory | Path display + click to change (NSOpenPanel) |
| Filename template | Text field supporting tokens: `%project`, `%date`, `%time` |
| Video codec | Picker: `H.264` / `H.265` / `ProRes 422` |
| Audio codec | Picker: `AAC 192kbps` / `AAC 256kbps` / `PCM` |
| Include subtitles | Toggle (burn-in vs clean export) |
| Export sidecars | Toggle group: `.ass`, `words.json`, and optional export metadata. Sidecars are copied beside the final video when enabled. |
| FFmpeg binary path | Auto-detected; override field for custom installs |
| `Verify FFmpeg` button | Runs diagnostic, shows libass availability |
| Export Log | Collapsible accordion showing last FFmpeg stdout/stderr. Errors in red. `Open in TextEdit` link. |
| `Export` button | Duplicates top-bar export button |

---

## 9. Project File Extensions (`.speechproj`)

Extend the existing JSON structure with the following top-level keys:

```jsonc
{
  "tracks": [
    {
      "id": "uuid",
      "type": "narration | music | sfx | subtitleOverride | video",
      "name": "Narration 1",
      "colour": "#FF6B6B",
      "muted": false,
      "solo": false,
      "hidden": false,
      "locked": false,
      "volume": 1.0,       // 0.0–2.0
      "order": 0           // display order top-to-bottom
    }
  ],
  "narrationClips": [
    {
      "id": "uuid",
      "trackId": "uuid",
      "startTime": 0.0,    // seconds
      "audioFilePath": "~/Library/.../AudioImports/clip.m4a",
      "text": "Hello world",
      "words": [
        { "word": "Hello", "startTime": 0.0, "duration": 0.4 },
        { "word": "world", "startTime": 0.45, "duration": 0.5 }
      ],
      "subtitleStyleOverride": null  // or SubtitleStyleSettings object
    }
  ],
  "mediaClips": [
    {
      "id": "uuid",
      "trackId": "uuid",
      "startTime": 0.0,
      "duration": 30.0,
      "audioFilePath": "~/Library/.../AudioImports/music.m4a",
      "volume": 0.7,
      "fadeInDuration": 1.0,
      "fadeOutDuration": 2.0,
      "loop": false
    }
  ],
  "subtitleStyleSettings": { /* existing SubtitleStyleSettings */ },
  "videoAudioMuted": false,
  "videoAudioVolume": 1.0,
  "exportSettings": {
    "outputDirectory": "~/Desktop",
    "filenameTemplate": "%project_%date",
    "videoCodec": "h264",
    "audioCodec": "aac_192",
    "includeSubtitles": true,
    "sidecarArtifacts": {
      "ass": false,
      "wordsJson": false,
      "metadata": false
    }
  }
}
```

---

## 10. Swift Data Structures (Reference)

```swift
// Extend or add alongside existing ProjectNarration

struct TrackDescriptor: Identifiable, Codable {
    var id: UUID
    var type: TrackType
    var name: String
    var colour: String          // hex
    var muted: Bool
    var solo: Bool
    var hidden: Bool
    var locked: Bool
    var volume: Float           // 0.0–2.0
    var order: Int
}

enum TrackType: String, Codable {
    case video, narration, music, sfx, subtitleOverride
}

struct NarrationClip: Identifiable, Codable {
    var id: UUID
    var trackId: UUID
    var startTime: Double       // seconds
    var audioFilePath: String
    var text: String
    var words: [WordTiming]
    var subtitleStyleOverride: SubtitleStyleSettings?
}

struct WordTiming: Codable {
    var word: String
    var startTime: Double
    var duration: Double
}

struct MediaClip: Identifiable, Codable {
    var id: UUID
    var trackId: UUID
    var startTime: Double
    var duration: Double
    var audioFilePath: String
    var volume: Float
    var fadeInDuration: Double
    var fadeOutDuration: Double
    var loop: Bool
}

struct ExportSettings: Codable {
    var outputDirectory: String
    var filenameTemplate: String
    var videoCodec: VideoCodec
    var audioCodec: AudioCodec
    var includeSubtitles: Bool
    var sidecarArtifacts: SidecarArtifactSettings
}

struct SidecarArtifactSettings: Codable {
    var ass: Bool
    var wordsJson: Bool
    var metadata: Bool
}

enum VideoCodec: String, Codable { case h264, h265, prores422 }
enum AudioCodec: String, Codable { case aac192, aac256, pcm }
```

---

## 11. Phased Implementation Plan

> All phases must pass `swift build` with zero warnings before merging.

### Phase A — Track Data Model (est. 3 days)

- [x] Define `TrackDescriptor`, `NarrationClip`, `MediaClip`, `ExportSettings` Swift structs.
- [x] Extend `.speechproj` serialisation to include all new keys; maintain backward compatibility (missing keys → sensible defaults).
- [x] Implement `ProjectStore` CRUD: `addTrack`, `deleteTrack`, `reorderTrack`, `addClip`, `deleteClip`, `moveClip`.
- [x] Overlap detection function: given a `TrackDescriptor` and a proposed `NarrationClip`, return all overlapping clips.
- [x] Auto-nudge function: returns the earliest non-overlapping `startTime` for a clip on a given track.
- [ ] Unit tests for overlap detection and auto-nudge edge cases.

### Phase B — Track Header UI (est. 3 days)

- [ ] `TrackHeaderView`: colour swatch, name label (inline edit), M/S/👁/🔒 toggle buttons, volume knob, expand arrow.
- [ ] Solo logic: toggling solo on one track mutes all others; stores previous mute states; restoring un-solo restores them.
- [ ] Drag-to-reorder track headers. Blue insertion indicator. Updates `TrackDescriptor.order`.
- [x] `+` Add Track popover.
- [x] Delete Track confirmation sheet.
- [ ] Video track header: mute original audio toggle + volume knob only.

### Phase C — Clip Rendering on Canvas (est. 4 days)

- [ ] `ClipCanvasView` as `NSViewRepresentable` wrapping a custom `NSView` (or pure SwiftUI with `Canvas` if perf allows).
- [ ] Render video thumbnail frames (pre-render to `CGImage` array on import).
- [ ] Render narration waveforms offline (pre-render from `.m4a` via `AVAssetReader` + Accelerate vDSP).
- [ ] Render music/SFX waveforms (same pipeline).
- [x] Subtitle pill on narration clips.
- [ ] Drag-to-move (horizontal only) with snap logic. Snap zone: 4 pt. `Option` key disables snap.
- [x] Overlap detection → yellow warning stripes. Timeline toolbar overlap badge.
- [ ] Selection state: selected clip highlighted, Inspector updates.
- [ ] Context menus per clip type.
- [ ] Trim handles on Music/SFX clips (drag left/right edges).
- [ ] Fade triangle handles on Music/SFX clips.
- [x] Lock check: locked clips reject drag gestures.

### Phase D — Audio Engine Integration (est. 4 days)

- [ ] `AudioMixEngine`: constructs `AVAudioEngine` graph from current `tracks` + `clips` state.
- [ ] One `AVAudioMixerNode` per track routed to main mixer.
- [ ] One `AVAudioPlayerNode` per `MediaClip` / `NarrationClip`, scheduled at `startTime`.
- [ ] Sync to `AVPlayer` clock on play/pause/seek. Reschedule all nodes on seek.
- [ ] Per-track volume, mute, solo wired to `AVAudioMixerNode.volume` / node connections.
- [ ] Per-clip volume applied at scheduling time.
- [ ] Fade-in/fade-out applied via `scheduleBuffer` volume ramp or manual gain automation.
- [ ] Mute audio during scrub; unmute on drag-end.
- [ ] Import audio files to `AudioImports` folder (mirror `VideoImports` logic including security-scoped resource access).

### Phase E — Inspector Panel Tabs (est. 3 days)

- [ ] Tab bar with 5 icon+label buttons. Highlight selected with system accent colour.
- [ ] **Clip tab:** all controls per Section 8.1. Word timing table with editable rows.
- [ ] **Subtitles tab:** all controls per Section 8.2. Wire to existing `SubtitleStyleSettings`.
- [ ] **Audio Mix tab:** channel strips. Sync fader/M/S state bidirectionally with track headers.
- [ ] **Appearance tab:** font picker, colour wells, required presets from Section 8.4.1, live mini-preview.
- [ ] **Export tab:** all fields per Section 8.5. FFmpeg verify button. Export log accordion. Sidecar toggles for `.ass`, `words.json`, and metadata.

### Phase F — Subtitle Compositor & Export Polish (est. 2 days)

- [ ] Multi-track subtitle compositor: at any given time, find all active Narration clips across all tracks; render subtitle from the lowest-`order` active track.
- [ ] Subtitle Override clips: supersede Narration subtitles for their time range.
- [ ] Video original audio: wire mute toggle and volume knob to the `AVPlayerNode` used by `AVPlayerView`.
- [ ] Update `.speechproj` serialisation with all new fields. Verify round-trip fidelity.
- [ ] Extend FFmpeg `.ass` export to merge clips from all Narration tracks (currently assumes single track).
- [ ] Implement sidecar artifact export: copy generated `.ass`, `words.json`, and metadata beside the final video when toggled on.

### Phase G — QA & Hardening (est. 2 days)

- [ ] Test all overlap scenarios: auto-nudge, intentional overlap (Option key), resolve overlap menu actions.
- [ ] Test solo/mute with 5+ tracks including edge case: solo the only un-muted track.
- [ ] Test seek to arbitrary position with 3+ narration clips and 2 music clips active.
- [ ] Test export: 0 narration clips, 1, 5+, with and without original audio muted, with music/SFX.
- [ ] Test project save/reopen fidelity: all tracks, all clips, all settings restored identically.
- [ ] Test backward compatibility: open an old `.speechproj` with no `tracks` key — defaults applied, no crash.
- [ ] `swift build` zero warnings at end of every phase.

---

## 12. Constraints & Non-Negotiable Decisions

These decisions are already made in `AGENTS.md` and must not be reversed:

| Decision | Reason |
|---|---|
| Use `NSViewRepresentable` + `AVPlayerView`, not SwiftUI `VideoPlayer` | SIGABRT in `_AVKit_SwiftUI` during import |
| Normal macOS title bar (not hidden) | Hidden titlebar causes preview to cover controls |
| No Whisper/forced-alignment backend | Model footprint exceeds 100 MB budget |
| Use `/tts-file` for placed clips (not `/tts` streaming) | Streaming is for preview only; saved clips need complete file |
| Saved audio as `.m4a` (not `.wav`) | macOS/iOS compatibility |
| Video files copied to `VideoImports` before `AVFoundation` loads | Stable path, avoids security-scoped URL lifetime issues |

---

## 13. Out of Scope

- Python backend Phase 4 endpoint (`/export/video-with-word-subtitles`) — export is fully Swift-side.
- Bundled FFmpeg/ffprobe installer — user installs via Homebrew.
- VTT / SRT export as standalone artifacts. `.ass` and `words.json` sidecar export are in scope via Export settings.
- Original audio mixing with pitch-corrected speed changes.
- Timeline markers / chapter points.
- Multi-camera or B-roll tracks.
- Undo/redo stack (desired future work, not in this PRD).


# How to reduce risks

This redesign should be implemented phase by phase. Do **not** start by rebuilding the full UI. The safest path is to first stabilize the project model and the audio/timeline architecture, then connect the UI once the core behavior is proven.

The highest-risk area is the live audio engine: `AVAudioEngine`, multi-node scheduling, multi-track playback, seek behavior, and synchronization with `AVPlayer`. Timeline UI work is still complex, but it is lower risk because most UI problems are visible immediately. Audio timing bugs are harder to detect because they can appear as small offsets, drift, glitches, or broken node state after seeking.

---

## 1. Build the data model first

Before redesigning the UI, add the new project structure:

- Tracks
- Clips
- Export settings
- Subtitle events
- Audio settings
- Backward-compatible defaults

The old project format should still load correctly. Existing data such as `videoURL` and narrations should migrate into the new model automatically:

- `videoURL` becomes a video track
- Existing narrations become narration clips
- A default narration track is created if needed
- Missing new fields receive safe defaults

This prevents the UI from being built on temporary state that will later need to be replaced.

---

## 2. Use one source of truth

Preview and export must read from the same track/clip model.

Avoid duplicate hidden state such as separate preview-only clips, export-only timing, or UI-only audio settings. The timeline, preview player, audio engine, subtitle system, and FFmpeg export should all consume the same project model.

This reduces the risk of bugs where preview looks correct but export is different.

---

## 3. Add a render/playback plan layer

Before preview or export, generate a plain intermediate structure, for example:

```swift
struct PlaybackPlan {
    let activeClips: [ResolvedClip]
    let startTime: TimeInterval
    let endTime: TimeInterval
    let volumes: [TrackID: Double]
    let subtitleEvents: [SubtitleEvent]
    let audioRoutes: [AudioRoute]
}
```

The render/playback plan should resolve:

- Which clips are active
- Clip start and end times
- Track volume
- Clip volume
- Mute/solo state
- Subtitle timing
- Audio routing
- Export-sidecar behavior

Both preview and export should consume this plan. This makes the system easier to debug because the app can print or inspect the plan before playback/export starts.

---

## 4. Build the audio engine in isolation first

Before wiring the real timeline UI to live audio, create a small standalone Swift test harness, such as a simple `NSWindowController` with basic buttons.

The harness should prove that the audio engine can handle:

- One narration clip at an arbitrary start time
- Two narration clips with correct offsets relative to `AVPlayer`
- Seeking to any timeline position
- Rescheduling clips correctly after seek
- Starting playback from the middle of a clip
- Mute, solo, and volume changes without graph crashes or glitches

Do not depend on SwiftUI view updates for this test. The goal is to prove the audio engine independently.

---

## 5. Keep the audio engine decoupled from SwiftUI

Create an `AudioMixEngine` as a plain Swift class with its own internal state.

The UI should call explicit methods such as:

```swift
audioMixEngine.play()
audioMixEngine.pause()
audioMixEngine.seek(to: time)
audioMixEngine.setTrackMuted(trackID, true)
audioMixEngine.setTrackVolume(trackID, volume)
```

The engine should not directly observe `@Published` properties or depend on SwiftUI view redraws. This avoids accidental graph changes during view updates and makes the engine easier to test.

---

## 6. Treat `AVPlayer` as the ground-truth clock

Use one `AVPlayer` as the master timeline clock.

Every audio node offset should be calculated from the current player time:

```swift
nodeStartOffset = clipStartTime - currentPlayerTime
```

On every seek, prefer the simple and reliable approach:

1. Stop scheduled audio.
2. Clear pending buffers.
3. Read the current `AVPlayer` time.
4. Rebuild the playback plan.
5. Reschedule clips from scratch.

Do not try to optimize with partial rescheduling at first. Correctness is more important than cleverness.

---

## 7. Implement audio complexity in small layers

Add audio features in this exact order, with each step acting as a merge gate:

1. Single narration clip, no seek
2. Single narration clip with seek support
3. Multiple narration clips on one track
4. Narration plus music/SFX clips
5. Mute, solo, and volume
6. Fade-in and fade-out
7. Looping

Do not move to the next step until the current one is proven. If something breaks, this makes it clear which feature introduced the regression.

---

## 8. Build timeline UI with a mock audio engine first

The timeline UI can be developed against a `MockAudioEngine` before the real audio engine is connected.

The mock engine should print or log actions such as:

- Play
- Pause
- Seek
- Clip moved
- Clip trimmed
- Track muted
- Volume changed

This allows the timeline UI, drag behavior, snapping, headers, inspectors, selection, and project model updates to be built without debugging live audio at the same time.

---

## 9. Pre-render expensive visual assets

Waveforms and thumbnails should be generated once and cached.

Do not recalculate waveform or thumbnail data during timeline drawing or scrolling. Timeline rendering should only read prepared lightweight display data.

Cacheable assets include:

- Audio waveforms
- Video thumbnails
- Clip preview frames
- Subtitle layout previews if needed

This keeps the timeline responsive as project complexity grows.

---

## 10. Write timing accuracy tests

Add tests that verify actual playback timing, not just whether audio plays.

Use an `AVAudioEngine` tap or another measurement mechanism to record when clips actually start, then compare that against the expected timeline time.

Suggested threshold:

```swift
abs(actualStartTime - expectedStartTime) < 0.020
```

A 20ms threshold is a reasonable starting point for detecting sync problems that may not be obvious during casual listening but can still break subtitle alignment.

Test cases should include:

- 0 clips
- 1 narration clip
- 3 narration clips
- Overlapping clips
- Music plus narration
- Muted original audio
- Seek into the middle of a clip
- Export with sidecars

---

## 11. Keep FFmpeg export last

FFmpeg export is lower risk than the live preview engine because export is deterministic and can be tested from generated fixtures.

Implement it after:

1. The project model is stable
2. The render/playback plan exists
3. The audio engine behavior is validated
4. Timeline UI edits correctly update the model

Export should use the same resolved plan as preview, so preview and final render stay consistent.

---

## 12. Suggested implementation priority

| Priority | Task | Risk | Notes |
|---|---|---|---|
| 1 | Project data model migration | High | Must happen before full UI redesign |
| 2 | Playback/render plan | High | Shared by preview and export |
| 3 | AudioMixEngine isolation harness | High | Prove sync, seek, mute, solo, volume |
| 4 | Clock sync and seek correctness | High | `AVPlayer` should be the source of truth |
| 5 | Timeline UI with mock audio | Medium | Can be built in parallel |
| 6 | Connect UI to real audio engine | Medium | Only after both sides are stable |
| 7 | Waveform/thumbnail caching | Medium | Needed for timeline performance |
| 8 | FFmpeg multi-track export | Low/Medium | Implement after plan/model are stable |

---

## Coding agent instruction

Start with the data model and migration layer. Then add the playback/render plan. In parallel, build the timeline UI against a mock audio engine and build the real `AudioMixEngine` in an isolated harness.

Do not wire the real audio engine directly into the full SwiftUI timeline until:

- The model migration works
- The playback/render plan is inspectable
- The isolated audio harness passes seek and sync tests
- The timeline UI works with mock audio

The goal is to avoid debugging project migration, timeline UI, live audio, seeking, and export behavior all at the same time.
