import SwiftUI
import AVKit
import AppKit

struct PlayerPreviewView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

struct ExportDiagnosticsView: View {
    let log: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Export Diagnostics")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            ScrollView {
                Text(log.isEmpty ? "No FFmpeg log was captured." : log)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 420)
    }
}

struct SubtitlePreviewOverlay: View {
    let narration: ProjectNarration
    let currentTime: Double
    let style: SubtitleStyleSettings
    let previewSize: CGSize

    private var activeGroup: [ExportTimedWord] {
        PreviewTimingBuilder.activeGroup(
            for: narration,
            currentTime: currentTime,
            style: style
        )
    }

    private var activeWordID: Int? {
        guard style.isWordHighlightingEnabled else { return nil }
        return activeGroup.first { currentTime >= $0.start && currentTime <= $0.end }?.index
    }

    var body: some View {
        VStack {
            Spacer()

            if !activeGroup.isEmpty {
                HStack(spacing: 7) {
                    ForEach(activeGroup) { word in
                        Text(word.word)
                            .font(.system(size: previewFontSize, weight: word.index == activeWordID ? .heavy : .bold, design: .rounded))
                            .foregroundStyle(word.index == activeWordID ? Color(hex: style.activeWordColorHex) : Color(hex: style.textColorHex))
                            .shadow(color: .black, radius: 2, x: 0, y: 1)
                    }
                }
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.45)
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
                .padding(.bottom, previewBottomMargin)
                .frame(maxWidth: previewSize.width - 44)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: activeGroup)
    }

    private var previewFontSize: Double {
        max(10, style.fontSize * Double(previewSize.width / 1920))
    }

    private var previewBottomMargin: Double {
        max(6, style.bottomMargin * Double(previewSize.height / 1080))
    }
}

enum PreviewTimingBuilder {
    static func activeGroup(
        for narration: ProjectNarration,
        currentTime: Double,
        style: SubtitleStyleSettings
    ) -> [ExportTimedWord] {
        guard narration.duration > 0 else { return [] }
        let words = ExportTimingBuilder.wordTimings(
            for: narration,
            mode: style.timingMode
        )
        let shiftedWords = ExportTimingBuilder.shiftedTimings(words, offset: style.timingOffset)
        guard let activeWord = shiftedWords.first(where: { currentTime >= $0.start && currentTime <= $0.end }) else {
            return []
        }

        return ASSSubtitleRenderer
            .groupWords(shiftedWords, maxWords: style.maxWordsPerLine)
            .first { group in group.contains { $0.index == activeWord.index } } ?? []
    }
}

struct SubtitleStylePanel: View {
    @Binding var style: SubtitleStyleSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Subtitles")
                    .font(.headline)

                Toggle("Word Highlighting", isOn: $style.isWordHighlightingEnabled)

                VStack(alignment: .leading, spacing: 10) {
                    Picker("Timing", selection: $style.timingMode) {
                        ForEach(SubtitleTimingMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    ColorPicker("Current word", selection: colorBinding(for: \.activeWordColorHex), supportsOpacity: false)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Timing offset")
                            Spacer()
                            Text(offsetLabel)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $style.timingOffset, in: -0.75...0.75, step: 0.01)
                        HStack(spacing: 8) {
                            Button(action: { style.timingOffset = max(-0.75, style.timingOffset - 0.05) }) {
                                Image(systemName: "minus")
                            }
                            Button(action: { style.timingOffset = 0 }) {
                                Image(systemName: "arrow.counterclockwise")
                            }
                            Button(action: { style.timingOffset = min(0.75, style.timingOffset + 0.05) }) {
                                Image(systemName: "plus")
                            }
                        }
                        .buttonStyle(.borderless)
                        .help("Adjust subtitle timing")
                    }
                }
                .disabled(!style.isWordHighlightingEnabled)
                .opacity(style.isWordHighlightingEnabled ? 1 : 0.45)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Size")
                        Spacer()
                        Text("\(Int(style.fontSize.rounded()))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $style.fontSize, in: 28...96, step: 1)
                }

                Stepper(value: $style.maxWordsPerLine, in: 2...9) {
                    HStack {
                        Text("Words per line")
                        Spacer()
                        Text("\(style.maxWordsPerLine)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    ColorPicker("General text", selection: colorBinding(for: \.textColorHex), supportsOpacity: false)
                    ColorPicker("Outline", selection: colorBinding(for: \.outlineColorHex), supportsOpacity: false)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Bottom margin")
                        Spacer()
                        Text("\(Int(style.bottomMargin.rounded()))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $style.bottomMargin, in: 24...180, step: 1)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(red: 0.12, green: 0.12, blue: 0.13))
        .foregroundStyle(.white)
    }

    private func colorBinding(for keyPath: WritableKeyPath<SubtitleStyleSettings, String>) -> Binding<Color> {
        Binding(
            get: { Color(hex: style[keyPath: keyPath]) },
            set: { style[keyPath: keyPath] = $0.hexString() }
        )
    }

    private var offsetLabel: String {
        String(format: "%+.2fs", style.timingOffset)
    }
}

extension Color {
    init(hex: String) {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard trimmed.count == 6, let value = Int(trimmed, radix: 16) else {
            self = .white
            return
        }

        self = Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    func hexString() -> String {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let red = max(0, min(255, Int((color.redComponent * 255).rounded())))
        let green = max(0, min(255, Int((color.greenComponent * 255).rounded())))
        let blue = max(0, min(255, Int((color.blueComponent * 255).rounded())))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
