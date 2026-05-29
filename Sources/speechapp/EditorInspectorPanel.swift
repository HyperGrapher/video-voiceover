import SwiftUI
import AppKit

enum InspectorTab: String, CaseIterable, Identifiable {
    case clip
    case subtitles
    case audioMix
    case appearance
    case export

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clip: "Clip"
        case .subtitles: "Subtitles"
        case .audioMix: "Audio Mix"
        case .appearance: "Appearance"
        case .export: "Export"
        }
    }

    var icon: String {
        switch self {
        case .clip: "film"
        case .subtitles: "captions.bubble.fill"
        case .audioMix: "waveform"
        case .appearance: "paintbrush"
        case .export: "square.and.arrow.up"
        }
    }
}

struct EditorInspectorPanel: View {
    @Binding var project: SpeechAppProject
    let selectedNarrationClipID: UUID?
    let isRendering: Bool
    let exportLog: String
    let onExport: () -> Void

    @State private var selectedTab: InspectorTab = .subtitles
    @State private var isShowingExportLog = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                ForEach(InspectorTab.allCases) { tab in
                    Button(action: { selectedTab = tab }) {
                        VStack(spacing: 3) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 21))
                            Text(tab.title)
                                .font(.caption2)
                        }
                        .foregroundStyle(selectedTab == tab ? Color.accentColor : .primary)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .help(tab.title)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch selectedTab {
                    case .clip:
                        clipTab
                    case .subtitles:
                        subtitlesTab
                    case .audioMix:
                        audioMixTab
                    case .appearance:
                        appearanceTab
                    case .export:
                        exportTab
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var clipTab: some View {
        Group {
            if let clip = selectedNarrationClip {
                LabeledContent("Clip name") {
                    Text("Narration")
                }
                LabeledContent("Start time") {
                    Text(formatTimecode(clip.startTime))
                        .font(.system(.body, design: .monospaced))
                }
                LabeledContent("Duration") {
                    Text(formatTimecode(clip.duration))
                        .font(.system(.body, design: .monospaced))
                }
                TextEditor(text: .constant(clip.text))
                    .font(.body)
                    .frame(minHeight: 120)
                    .disabled(true)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6).stroke(.separator)
                    }
            } else {
                ContentUnavailableView("No Selection", systemImage: "cursorarrow.click", description: Text("Select a clip in the timeline to edit it."))
                    .frame(maxWidth: .infinity, minHeight: 220)
            }
        }
    }

    private var selectedNarrationClip: NarrationClip? {
        if let selectedNarrationClipID,
           let selectedClip = project.narrationClips.first(where: { $0.id == selectedNarrationClipID }) {
            return selectedClip
        }

        return project.narrationClips.first
    }

    private var subtitlesTab: some View {
        Group {
            Picker("Timing Mode", selection: $project.subtitleStyle.timingMode) {
                ForEach(SubtitleTimingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Toggle("Word Highlighting", isOn: $project.subtitleStyle.isWordHighlightingEnabled)
            LabeledContent("Timing Offset") {
                HStack {
                    Slider(value: $project.subtitleStyle.timingOffset, in: -0.5...0.5, step: 0.01)
                    Text(String(format: "%+.0f ms", project.subtitleStyle.timingOffset * 1000))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 58, alignment: .trailing)
                }
            }
            Picker("Subtitle Position", selection: $project.subtitleStyle.bottomMargin) {
                Text("Bottom").tag(58.0)
                Text("Top").tag(900.0)
                Text("Custom").tag(project.subtitleStyle.bottomMargin)
            }
            Stepper(value: $project.subtitleStyle.maxWordsPerLine, in: 1...8) {
                LabeledContent("Max words per event", value: "\(project.subtitleStyle.maxWordsPerLine)")
            }
            Picker("Line break mode", selection: .constant("fit")) {
                Text("Fit to line-length").tag("fit")
                Text("Fixed word count").tag("fixed")
            }
            Toggle("Preview overlay", isOn: .constant(true))
            Text("Settings apply to auto-generated subtitles and can be overridden per event in the timeline.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var audioMixTab: some View {
        HStack(alignment: .bottom, spacing: 14) {
            ForEach($project.tracks) { $track in
                if track.type != .subtitleOverride {
                    MixerStrip(track: $track)
                }
            }
            VStack(spacing: 8) {
                Text("Master")
                    .font(.caption.weight(.semibold))
                Slider(value: .constant(1.0), in: 0...2)
                    .rotationEffect(.degrees(-90))
                    .frame(width: 42, height: 150)
                Text("100%")
                    .font(.caption2.monospacedDigit())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var appearanceTab: some View {
        Group {
            Text("Welcome to SpeechApp")
                .font(.system(size: min(project.subtitleStyle.fontSize / 2, 34), weight: .heavy, design: .rounded))
                .foregroundStyle(Color(hex: project.subtitleStyle.activeWordColorHex))
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))

            SliderRow(title: "Font size", value: $project.subtitleStyle.fontSize, range: 12...96, suffix: " pt")
            ColorPicker("Primary colour", selection: colorBinding(for: \.activeWordColorHex), supportsOpacity: false)
            ColorPicker("Secondary colour", selection: colorBinding(for: \.textColorHex), supportsOpacity: false)
            ColorPicker("Outline colour", selection: colorBinding(for: \.outlineColorHex), supportsOpacity: false)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                presetButton("Clean White", active: "#FFD84D", text: "#FFFFFF", size: 54, margin: 58)
                presetButton("TikTok Yellow", active: "#FFF200", text: "#FFFFFF", size: 62, margin: 70)
                presetButton("Bold Meme", active: "#FFFFFF", text: "#FFFFFF", size: 76, margin: 34)
                presetButton("Minimal Lower Third", active: "#FFFFFF", text: "#F4F4F4", size: 38, margin: 96)
                presetButton("Dark Pill", active: "#FFD84D", text: "#FFFFFF", size: 50, margin: 58)
            }
        }
    }

    private var exportTab: some View {
        Group {
            LabeledContent("Output directory") {
                Text(project.exportSettings.outputDirectory)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            TextField("Filename template", text: $project.exportSettings.filenameTemplate)
            Picker("Video codec", selection: $project.exportSettings.videoCodec) {
                Text("H.264").tag(VideoCodec.h264)
                Text("H.265").tag(VideoCodec.h265)
                Text("ProRes 422").tag(VideoCodec.prores422)
            }
            Picker("Audio codec", selection: $project.exportSettings.audioCodec) {
                Text("AAC 192kbps").tag(AudioCodec.aac192)
                Text("AAC 256kbps").tag(AudioCodec.aac256)
                Text("PCM").tag(AudioCodec.pcm)
            }
            Toggle("Include subtitles", isOn: $project.exportSettings.includeSubtitles)
            Toggle(".ass sidecar", isOn: $project.exportSettings.sidecarArtifacts.ass)
            Toggle("words.json sidecar", isOn: $project.exportSettings.sidecarArtifacts.wordsJson)
            Toggle("metadata sidecar", isOn: $project.exportSettings.sidecarArtifacts.metadata)
            Button(action: onExport) {
                Label(isRendering ? "Exporting" : "Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            DisclosureGroup("Export Log", isExpanded: $isShowingExportLog) {
                Text(exportLog.isEmpty ? "No export has run yet." : exportLog)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(exportLog.lowercased().contains("error") ? .red : .secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func colorBinding(for keyPath: WritableKeyPath<SubtitleStyleSettings, String>) -> Binding<Color> {
        Binding(
            get: { Color(hex: project.subtitleStyle[keyPath: keyPath]) },
            set: { project.subtitleStyle[keyPath: keyPath] = $0.hexString() }
        )
    }

    private func presetButton(_ title: String, active: String, text: String, size: Double, margin: Double) -> some View {
        Button(title) {
            project.subtitleStyle.activeWordColorHex = active
            project.subtitleStyle.textColorHex = text
            project.subtitleStyle.fontSize = size
            project.subtitleStyle.bottomMargin = margin
        }
    }
}
