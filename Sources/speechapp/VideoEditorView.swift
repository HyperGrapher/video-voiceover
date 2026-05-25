import SwiftUI
import AVFoundation
import AVKit
import AppKit
import UniformTypeIdentifiers

@MainActor
final class VideoEditorModel: ObservableObject {
    @Published var selectedVideoURL: URL?
    @Published var duration: Double = 0
    @Published var currentTime: Double = 0
    @Published var isPlaying = false
    @Published var statusMessage = "Import a video to begin arranging."

    let player = AVPlayer()

    func importVideo() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .movie,
            .mpeg4Movie,
            .quickTimeMovie,
            UTType(filenameExtension: "mkv") ?? .movie,
            UTType(filenameExtension: "webm") ?? .movie
        ]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            await loadVideo(url)
        }
    }

    func loadVideo(_ url: URL) async {
        stop()
        selectedVideoURL = url
        statusMessage = "Loading \(url.lastPathComponent)..."

        let asset = AVURLAsset(url: url)

        do {
            let loadedDuration = try await asset.load(.duration)
            let seconds = loadedDuration.seconds
            duration = seconds.isFinite ? max(seconds, 0) : 0
            currentTime = 0

            let item = AVPlayerItem(asset: asset)
            player.replaceCurrentItem(with: item)
            seek(to: 0)
            statusMessage = "Loaded \(url.lastPathComponent)"
        } catch {
            selectedVideoURL = nil
            duration = 0
            currentTime = 0
            player.replaceCurrentItem(with: nil)
            statusMessage = "Could not load video: \(error.localizedDescription)"
        }
    }

    func togglePlayback() {
        guard selectedVideoURL != nil else { return }

        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if duration > 0 && currentTime >= duration {
                seek(to: 0)
            }
            player.play()
            isPlaying = true
        }
    }

    func jumpToStart() {
        seek(to: 0)
    }

    func jumpToEnd() {
        seek(to: duration)
    }

    func seek(to seconds: Double) {
        let clamped = min(max(seconds, 0), duration)
        currentTime = clamped
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func syncCurrentTimeFromPlayer() {
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return }

        currentTime = min(max(seconds, 0), duration)
        if isPlaying && duration > 0 && currentTime >= duration {
            isPlaying = false
        }
    }

    private func stop() {
        player.pause()
        isPlaying = false
    }
}

struct VideoEditorView: View {
    @StateObject private var model = VideoEditorModel()
    private let playbackTimer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            editorHeader

            Divider()
                .overlay(Color.white.opacity(0.08))

            previewSection
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            transportBar

            TimelineViewShell(model: model)
                .frame(height: 260)
        }
        .foregroundStyle(.white)
        .background(Color(red: 0.105, green: 0.105, blue: 0.112))
        .onReceive(playbackTimer) { _ in
            model.syncCurrentTimeFromPlayer()
        }
    }

    private var editorHeader: some View {
        HStack(spacing: 12) {
            Button(action: model.importVideo) {
                Label("Import Video", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedVideoURL?.lastPathComponent ?? "Untitled Video Arrangement")
                    .font(.headline)
                    .lineLimit(1)
                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color(red: 0.14, green: 0.13, blue: 0.14))
    }

    private var previewSection: some View {
        GeometryReader { proxy in
            let previewWidth = min(proxy.size.width - 56, 960)
            let previewHeight = previewWidth * 9 / 16

            VStack {
                Spacer(minLength: 16)

                ZStack {
                    Rectangle()
                        .fill(Color.black)

                    if model.selectedVideoURL == nil {
                        VStack(spacing: 14) {
                            Image(systemName: "film")
                                .font(.system(size: 38, weight: .light))
                                .foregroundStyle(.white.opacity(0.42))
                            Text("Import a video")
                                .font(.title3.weight(.medium))
                            Text("The preview will appear here in a 16:9 canvas.")
                                .font(.callout)
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    } else {
                        VideoPlayer(player: model.player)
                            .background(Color.black)
                    }
                }
                .frame(width: previewWidth, height: previewHeight)
                .overlay {
                    Rectangle()
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.28), radius: 18, y: 10)

                Spacer(minLength: 16)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(Color(red: 0.30, green: 0.30, blue: 0.30))
        }
    }

    private var transportBar: some View {
        HStack(spacing: 20) {
            Spacer()

            Button(action: model.jumpToStart) {
                Image(systemName: "backward.end.fill")
            }
            .disabled(model.selectedVideoURL == nil)

            Button(action: model.togglePlayback) {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 30)
            }
            .disabled(model.selectedVideoURL == nil)

            Button(action: model.jumpToEnd) {
                Image(systemName: "forward.end.fill")
            }
            .disabled(model.selectedVideoURL == nil)

            Text("\(formatTime(model.currentTime)) / \(formatTime(model.duration))")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.white.opacity(0.86))
                .frame(width: 155, alignment: .leading)

            Spacer()
        }
        .buttonStyle(.plain)
        .padding(.vertical, 10)
        .background(Color(red: 0.095, green: 0.095, blue: 0.10))
    }
}

struct TimelineViewShell: View {
    @ObservedObject var model: VideoEditorModel

    private let labelColumnWidth: CGFloat = 84
    private let rulerHeight: CGFloat = 34
    private let trackHeight: CGFloat = 62
    private let tracks = [
        ("Video", "film", Color(red: 0.18, green: 0.34, blue: 0.54)),
        ("Audio", "waveform", Color(red: 0.19, green: 0.40, blue: 0.30)),
        ("Subtitles", "text.bubble", Color(red: 0.34, green: 0.25, blue: 0.46))
    ]

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let timelineWidth = max(proxy.size.width - labelColumnWidth, 1)
                let progress = progressValue
                let playheadX = labelColumnWidth + timelineWidth * progress

                ZStack(alignment: .topLeading) {
                    timelineBackground

                    VStack(spacing: 0) {
                        ruler(timelineWidth: timelineWidth)
                            .frame(height: rulerHeight)

                        ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                            trackRow(track, index: index, timelineWidth: timelineWidth)
                                .frame(height: trackHeight)
                        }
                    }

                    playhead
                        .position(x: playheadX, y: (rulerHeight + trackHeight * CGFloat(tracks.count)) / 2)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            seek(from: value.location.x, timelineWidth: timelineWidth)
                        }
                )
            }
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.085))
    }

    private var timelineBackground: some View {
        Rectangle()
            .fill(Color(red: 0.085, green: 0.085, blue: 0.09))
    }

    private func ruler(timelineWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color(red: 0.095, green: 0.095, blue: 0.10))
                .frame(width: labelColumnWidth)

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color(red: 0.095, green: 0.095, blue: 0.10))

                ForEach(rulerTicks, id: \.self) { second in
                    let x = tickX(second: second, width: timelineWidth)
                    VStack(spacing: 3) {
                        Rectangle()
                            .fill(Color.white.opacity(second.rounded() == second ? 0.38 : 0.18))
                            .frame(width: 1, height: second.rounded() == second ? 12 : 7)
                        if second.rounded() == second {
                            Text("\(Int(second))s")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.56))
                        }
                    }
                    .position(x: x, y: 17)
                }
            }
            .frame(width: timelineWidth)
        }
    }

    private func trackRow(
        _ track: (String, String, Color),
        index: Int,
        timelineWidth: CGFloat
    ) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: track.1)
                    .frame(width: 18)
                Text(track.0)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer()
            }
            .foregroundStyle(.white.opacity(0.70))
            .padding(.horizontal, 12)
            .frame(width: labelColumnWidth)
            .background(Color(red: 0.105, green: 0.105, blue: 0.112))

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(index == 0 ? Color(red: 0.10, green: 0.15, blue: 0.22) : Color(red: 0.105, green: 0.105, blue: 0.11))

                if model.selectedVideoURL != nil {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(track.2.opacity(index == 0 ? 0.90 : 0.56))
                        .frame(width: timelineWidth, height: 42)
                        .overlay(alignment: .leading) {
                            Text(index == 0 ? model.selectedVideoURL?.lastPathComponent ?? "Clip" : track.0)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                        }
                        .padding(.horizontal, 0)
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)
            }
            .frame(width: timelineWidth)
        }
    }

    private var playhead: some View {
        VStack(spacing: 0) {
            Triangle()
                .fill(Color(red: 1.0, green: 0.18, blue: 0.20))
                .frame(width: 18, height: 14)
            Rectangle()
                .fill(Color(red: 1.0, green: 0.18, blue: 0.20))
                .frame(width: 2)
        }
        .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
    }

    private var progressValue: CGFloat {
        guard model.duration > 0 else { return 0 }
        return CGFloat(min(max(model.currentTime / model.duration, 0), 1))
    }

    private var rulerTicks: [Double] {
        let fallbackDuration = max(model.duration, 13)
        let maxSecond = Int(ceil(fallbackDuration))
        return Array(0...maxSecond).map(Double.init)
    }

    private func tickX(second: Double, width: CGFloat) -> CGFloat {
        let total = max(model.duration, Double(rulerTicks.count - 1), 1)
        return width * CGFloat(second / total)
    }

    private func seek(from xPosition: CGFloat, timelineWidth: CGFloat) {
        guard model.duration > 0 else { return }
        let localX = min(max(xPosition - labelColumnWidth, 0), timelineWidth)
        model.seek(to: Double(localX / timelineWidth) * model.duration)
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

private func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "00:00:00" }

    let totalSeconds = max(Int(seconds.rounded(.down)), 0)
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let remainingSeconds = totalSeconds % 60

    return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
}
