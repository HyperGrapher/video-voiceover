import SwiftUI
import AppKit

struct TrackHeaderView: View {
    @Binding var track: TrackDescriptor
    @Binding var videoAudioMuted: Bool
    @Binding var videoAudioVolume: Float
    let onSolo: (Bool) -> Void
    let onDelete: () -> Void

    @State private var isEditingName = false

    var body: some View {
        HStack(spacing: 8) {
            ColorPicker("", selection: Binding(
                get: { Color(hex: track.colour) },
                set: { track.colour = $0.hexString() }
            ), supportsOpacity: false)
            .labelsHidden()
            .frame(width: 18)

            if isEditingName {
                TextField("Track name", text: $track.name)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .onSubmit { isEditingName = false }
            } else {
                Text(track.name)
                    .font(.callout)
                    .lineLimit(1)
                    .onTapGesture(count: 2) {
                        isEditingName = true
                    }
            }
            Spacer()
            if track.type == .video {
                Button(action: { videoAudioMuted.toggle() }) {
                    Image(systemName: videoAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .buttonStyle(.borderless)
                .help("Mute original audio")
                Button(action: { track.hidden.toggle() }) {
                    Image(systemName: track.hidden ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                Button(action: { track.locked.toggle() }) {
                    Image(systemName: track.locked ? "lock.fill" : "lock")
                }
                .buttonStyle(.borderless)
                Text("\(Int(videoAudioVolume * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            } else {
                Button("M") { track.muted.toggle() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                if track.type != .subtitleOverride {
                    Button("S") {
                        onSolo(!track.solo)
                    }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Button(action: { track.hidden.toggle() }) {
                    Image(systemName: track.hidden ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                Button(action: { track.locked.toggle() }) {
                    Image(systemName: track.locked ? "lock.fill" : "lock")
                }
                .buttonStyle(.borderless)
            }
            Button(action: { track.isExpanded.toggle() }) {
                Image(systemName: track.isExpanded ? "chevron.down" : "chevron.right")
            }
            .buttonStyle(.borderless)
            .help(track.isExpanded ? "Collapse track" : "Expand track")
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .contextMenu {
            if track.type != .video {
                Button(role: .destructive, action: onDelete) {
                    Text("Delete Track")
                }
            }
        }
    }
}

struct MixerStrip: View {
    @Binding var track: TrackDescriptor

    var body: some View {
        VStack(spacing: 8) {
            Rectangle()
                .fill(Color(hex: track.colour))
                .frame(width: 26, height: 5)
            Text(track.name)
                .font(.caption2)
                .lineLimit(1)
                .frame(width: 54)
            Slider(value: Binding(
                get: { Double(track.volume) },
                set: { track.volume = Float($0) }
            ), in: 0...2)
            .rotationEffect(.degrees(-90))
            .frame(width: 42, height: 140)
            Text("\(Int(track.volume * 100))%")
                .font(.caption2.monospacedDigit())
            HStack(spacing: 4) {
                Button("M") { track.muted.toggle() }
                Button("S") { track.solo.toggle() }
            }
            .controlSize(.mini)
        }
        .frame(width: 62)
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let suffix: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.rounded()))\(suffix)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: 1)
        }
    }
}

struct WaveformStrip: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let count = max(24, Int(size.width / 8))
            let spacing: CGFloat = 3
            let width = max(2, (size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            for index in 0..<count {
                let normalized = 0.25 + 0.75 * abs(sin(Double(index) * 0.73))
                let height = max(3, size.height * normalized)
                let rect = CGRect(
                    x: CGFloat(index) * (width + spacing),
                    y: (size.height - height) / 2,
                    width: width,
                    height: height
                )
                context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(color))
            }
        }
    }
}
