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
    @Published var isDropTargeted = false

    let player = AVPlayer()
    private let supportedVideoExtensions = ["mp4", "mov", "m4v", "mkv", "webm"]
    private var narrationURL: URL?
    private var narrationPlayer: AVAudioPlayer?
    var onVideoImported: ((URL) -> Void)?

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
            await importVideo(from: url)
        }
    }

    func loadDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            statusMessage = "Drop a video file such as .mp4, .mov, or .mkv."
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?

            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = item as? URL
            }

            Task { @MainActor in
                guard let url else {
                    self.statusMessage = "Could not read the dropped file."
                    return
                }

                guard self.isSupportedVideo(url) else {
                    self.statusMessage = "Unsupported video format: \(url.pathExtension)"
                    return
                }

                await self.importVideo(from: url)
            }
        }

        return true
    }

    func importVideo(from sourceURL: URL) async {
        stop()
        statusMessage = "Importing \(sourceURL.lastPathComponent)..."

        do {
            let importedURL = try copyVideoIntoAppStorage(sourceURL)
            await loadVideo(importedURL)
            if selectedVideoURL == importedURL {
                onVideoImported?(importedURL)
            }
        } catch {
            selectedVideoURL = nil
            duration = 0
            currentTime = 0
            narrationPlayer?.stop()
            player.replaceCurrentItem(with: nil)
            statusMessage = "Could not import video: \(error.localizedDescription)"
        }
    }

    private func loadVideo(_ url: URL) async {
        stop()
        selectedVideoURL = url
        statusMessage = "Loading \(url.lastPathComponent)..."

        let asset = AVURLAsset(url: url)

        do {
            let loadedDuration = try await asset.load(.duration)
            let seconds = loadedDuration.seconds
            duration = seconds.isFinite ? max(seconds, 0) : 0
            currentTime = 0

            guard duration > 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }

            let item = AVPlayerItem(asset: asset)
            player.replaceCurrentItem(with: item)
            seek(to: 0)
            statusMessage = "Loaded \(url.lastPathComponent)"
        } catch {
            selectedVideoURL = nil
            duration = 0
            currentTime = 0
            narrationPlayer?.stop()
            player.replaceCurrentItem(with: nil)
            statusMessage = "Could not load video: \(error.localizedDescription)"
        }
    }

    func loadProjectVideo(_ url: URL?) {
        guard selectedVideoURL != url else { return }

        guard let url else {
            selectedVideoURL = nil
            duration = 0
            currentTime = 0
            isPlaying = false
            narrationPlayer?.stop()
            player.replaceCurrentItem(with: nil)
            statusMessage = "Import a video to begin arranging."
            return
        }

        Task {
            await loadVideo(url)
        }
    }

    func loadProjectNarration(_ narration: ProjectNarration?) {
        guard narrationURL != narration?.url else { return }

        narrationPlayer?.stop()
        narrationPlayer = nil
        narrationURL = narration?.url
        player.isMuted = narration != nil

        guard let narration else {
            return
        }

        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: narration.url)
            audioPlayer.prepareToPlay()
            audioPlayer.currentTime = min(max(currentTime, 0), audioPlayer.duration)
            narrationPlayer = audioPlayer
            statusMessage = "Loaded narration \(narration.url.lastPathComponent)"
        } catch {
            statusMessage = "Could not load narration audio: \(error.localizedDescription)"
        }
    }

    func togglePlayback() {
        guard selectedVideoURL != nil else { return }

        if isPlaying {
            player.pause()
            narrationPlayer?.pause()
            isPlaying = false
        } else {
            if duration > 0 && currentTime >= duration {
                seek(to: 0)
            }
            player.play()
            playNarrationIfAvailable()
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
        syncNarration(to: clamped)
    }

    func syncCurrentTimeFromPlayer() {
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return }

        currentTime = min(max(seconds, 0), duration)
        if isPlaying && duration > 0 && currentTime >= duration {
            narrationPlayer?.stop()
            isPlaying = false
        }
    }

    private func stop() {
        player.pause()
        narrationPlayer?.pause()
        isPlaying = false
    }

    private func playNarrationIfAvailable() {
        guard let narrationPlayer else { return }

        syncNarration(to: currentTime)
        if currentTime < narrationPlayer.duration {
            narrationPlayer.play()
        }
    }

    private func syncNarration(to seconds: Double) {
        guard let narrationPlayer else { return }

        let clamped = min(max(seconds, 0), narrationPlayer.duration)
        narrationPlayer.currentTime = clamped
        if isPlaying && clamped < narrationPlayer.duration && !narrationPlayer.isPlaying {
            narrationPlayer.play()
        }
        if clamped >= narrationPlayer.duration {
            narrationPlayer.pause()
        }
    }

    private func isSupportedVideo(_ url: URL) -> Bool {
        supportedVideoExtensions.contains(url.pathExtension.lowercased())
    }

    private func copyVideoIntoAppStorage(_ sourceURL: URL) throws -> URL {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let directory = try videoImportsDirectory()
        let destinationURL = uniqueImportedVideoURL(for: sourceURL, in: directory)

        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    private func videoImportsDirectory() throws -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = root.appendingPathComponent("speechapp/VideoImports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func uniqueImportedVideoURL(for sourceURL: URL, in directory: URL) -> URL {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let fileExtension = sourceURL.pathExtension
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        let safeBaseName = sanitizedFilename(baseName)

        return directory.appendingPathComponent("\(timestamp)_\(safeBaseName).\(fileExtension)")
    }

    private func sanitizedFilename(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let sanitized = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return sanitized.isEmpty ? "video" : sanitized
    }
}

struct VideoEditorView: View {
    @EnvironmentObject var backend: BackendProcessManager

    @Binding var project: SpeechAppProject
    let projectURL: URL
    let onCloseProject: () -> Void

    @StateObject private var model = VideoEditorModel()
    @State private var isShowingNarration = false
    @State private var renderMessage = ""
    private let playbackTimer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    private var activeNarration: ProjectNarration? {
        project.narrations.first
    }

    var body: some View {
        VStack(spacing: 0) {
            editorHeader

            Divider()
                .overlay(Color.white.opacity(0.08))

            previewSection
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            transportBar

            TimelineViewShell(model: model, project: project)
                .frame(height: 260)
        }
        .foregroundStyle(.white)
        .background(Color(red: 0.105, green: 0.105, blue: 0.112))
        .sheet(isPresented: $isShowingNarration) {
            SpeechNarrationView(onPlaceRecording: placeNarrationIntoTrack)
                .environmentObject(backend)
        }
        .onAppear {
            model.onVideoImported = { url in
                project.videoURL = url
            }
            model.loadProjectVideo(project.videoURL)
            model.loadProjectNarration(activeNarration)
        }
        .onChange(of: project.videoURL) { _, newURL in
            model.loadProjectVideo(newURL)
        }
        .onChange(of: project.narrations) { _, _ in
            model.loadProjectNarration(activeNarration)
        }
        .onReceive(playbackTimer) { _ in
            model.syncCurrentTimeFromPlayer()
        }
    }

    private var editorHeader: some View {
        HStack(spacing: 12) {
            Button(action: onCloseProject) {
                Label("Projects", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.white.opacity(0.82))

            Button(action: model.importVideo) {
                Label("Import Video", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)

            Button(action: { isShowingNarration = true }) {
                Label("Add Narration", systemImage: "waveform.and.mic")
            }
            .buttonStyle(.bordered)

            Button(action: renderVideoWithSubtitles) {
                Label("Render", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .disabled(project.videoURL == nil || project.narrations.isEmpty)
            .help(renderButtonHelp)

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(editorStatusLine)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.leading, 18)
        .padding(.trailing, 18)
        .padding(.vertical, 12)
        .background(Color(red: 0.14, green: 0.13, blue: 0.14))
    }

    private var previewSection: some View {
        GeometryReader { proxy in
            let maxPreviewWidth = max(proxy.size.width - 56, 240)
            let maxPreviewHeight = max(proxy.size.height - 32, 140)
            let previewWidth = min(maxPreviewWidth, maxPreviewHeight * 16 / 9, 960)
            let previewHeight = previewWidth * 9 / 16

            VStack {
                Spacer(minLength: 16)

                ZStack {
                    Rectangle()
                        .fill(Color.black)

                    if model.selectedVideoURL == nil {
                        VStack(spacing: 16) {
                            Button(action: model.importVideo) {
                                VStack(spacing: 14) {
                                    Image(systemName: "film")
                                        .font(.system(size: 42, weight: .light))
                                        .foregroundStyle(.white.opacity(0.46))
                                    Text("Import a video")
                                        .font(.title2.weight(.semibold))
                                    Text("Click Choose Video or drag a file here from Finder.")
                                        .font(.callout)
                                        .foregroundStyle(.white.opacity(0.58))
                                }
                            }
                            .buttonStyle(.plain)

                            Button(action: model.importVideo) {
                                Label("Choose Video...", systemImage: "folder")
                                    .frame(minWidth: 160)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                        .padding(28)
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(
                                    model.isDropTargeted ? Color(red: 1.0, green: 0.18, blue: 0.20) : Color.white.opacity(0.20),
                                    style: StrokeStyle(lineWidth: model.isDropTargeted ? 2 : 1, dash: [8, 6])
                                )
                        }
                    } else {
                        PlayerPreviewView(player: model.player)
                            .background(Color.black)

                        if let activeNarration {
                            SubtitlePreviewOverlay(
                                narration: activeNarration,
                                currentTime: model.currentTime
                            )
                            .allowsHitTesting(false)
                        }
                    }
                }
                .frame(width: previewWidth, height: previewHeight)
                .contentShape(Rectangle())
                .onTapGesture {
                    if model.selectedVideoURL == nil {
                        model.importVideo()
                    }
                }
                .onDrop(
                    of: [UTType.fileURL.identifier],
                    isTargeted: $model.isDropTargeted,
                    perform: model.loadDroppedProviders
                )
                .overlay {
                    Rectangle()
                        .stroke(model.isDropTargeted ? Color(red: 1.0, green: 0.18, blue: 0.20) : Color.white.opacity(0.08), lineWidth: model.isDropTargeted ? 2 : 1)
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

    private var editorStatusLine: String {
        let base = "\(projectURL.lastPathComponent) - \(model.statusMessage)"
        guard !renderMessage.isEmpty else { return base }
        return "\(base) - \(renderMessage)"
    }

    private var renderButtonHelp: String {
        if project.videoURL == nil {
            return "Import a video before rendering."
        }
        if project.narrations.isEmpty {
            return "Generate and place narration before rendering."
        }
        return "Export video with generated narration and word-synced subtitles."
    }

    private func placeNarrationIntoTrack(_ narration: ProjectNarration) {
        if !project.audioURLs.contains(narration.url) {
            project.audioURLs.append(narration.url)
        }

        project.narrations.append(narration)
        model.loadProjectNarration(narration)
        renderMessage = "Narration placed into audio/subtitle tracks"
        isShowingNarration = false
    }

    private func renderVideoWithSubtitles() {
        guard project.videoURL != nil else {
            renderMessage = "Import a video before rendering"
            return
        }

        guard !project.narrations.isEmpty else {
            renderMessage = "Generate and place narration before rendering"
            return
        }

        renderMessage = "Render pipeline UI is ready; FFmpeg export wiring is next"
    }
}

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

struct SubtitlePreviewOverlay: View {
    let narration: ProjectNarration
    let currentTime: Double

    private var activeGroup: [PreviewTimedWord] {
        PreviewTimingBuilder.activeGroup(
            for: narration.transcript,
            duration: narration.duration,
            currentTime: currentTime
        )
    }

    private var activeWordID: Int? {
        activeGroup.first { currentTime >= $0.start && currentTime <= $0.end }?.index
    }

    var body: some View {
        VStack {
            Spacer()

            if !activeGroup.isEmpty {
                HStack(spacing: 7) {
                    ForEach(activeGroup) { word in
                        Text(word.word)
                            .font(.system(size: 34, weight: word.index == activeWordID ? .heavy : .bold, design: .rounded))
                            .foregroundStyle(word.index == activeWordID ? Color(red: 1.0, green: 0.86, blue: 0.18) : .white)
                            .shadow(color: .black, radius: 2, x: 0, y: 1)
                    }
                }
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.55)
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
                .padding(.bottom, 34)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: activeGroup)
    }
}

struct PreviewTimedWord: Identifiable, Hashable {
    let index: Int
    let word: String
    let start: Double
    let end: Double

    var id: Int { index }
}

enum PreviewTimingBuilder {
    static func activeGroup(for transcript: String, duration: Double, currentTime: Double) -> [PreviewTimedWord] {
        guard duration > 0 else { return [] }
        let words = approximateTimings(for: transcript, duration: duration)
        guard let activeIndex = words.firstIndex(where: { currentTime >= $0.start && currentTime <= $0.end }) else {
            return []
        }

        let groupStart = max(0, activeIndex - activeIndex % 6)
        let groupEnd = min(words.count, groupStart + 6)
        return Array(words[groupStart..<groupEnd])
    }

    private static func approximateTimings(for transcript: String, duration: Double) -> [PreviewTimedWord] {
        let tokens = tokenize(transcript)
        guard !tokens.isEmpty else { return [] }

        let weights = tokens.map { max(1, $0.count) }
        let totalWeight = max(weights.reduce(0, +), 1)
        var current = 0.0
        var result: [PreviewTimedWord] = []

        for tokenIndex in tokens.indices {
            let end: Double
            if tokenIndex == tokens.count - 1 {
                end = duration
            } else {
                end = min(duration, current + duration * Double(weights[tokenIndex]) / Double(totalWeight))
            }

            result.append(PreviewTimedWord(
                index: tokenIndex,
                word: tokens[tokenIndex],
                start: current,
                end: end
            ))
            current = end
        }

        return result
    }

    private static func tokenize(_ transcript: String) -> [String] {
        transcript
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .flatMap { chunk in
                chunk
                    .split { character in
                        character.isPunctuation && character != "'" && character != "-"
                    }
                    .map(String.init)
            }
            .filter { !$0.isEmpty }
    }
}

struct TimelineViewShell: View {
    @ObservedObject var model: VideoEditorModel
    let project: SpeechAppProject

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
                .onTapGesture { location in
                    seek(from: location.x, timelineWidth: timelineWidth)
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            seek(from: value.location.x, timelineWidth: timelineWidth)
                        }
                )
                .onHover { isHovering in
                    if isHovering {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.pop()
                    }
                }
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

                if shouldShowClip(for: index) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(track.2.opacity(index == 0 ? 0.90 : 0.56))
                        .frame(width: clipWidth(for: index, timelineWidth: timelineWidth), height: 42)
                        .overlay(alignment: .leading) {
                            Text(trackTitle(for: index))
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

    private func shouldShowClip(for trackIndex: Int) -> Bool {
        switch trackIndex {
        case 0:
            return model.selectedVideoURL != nil
        case 1, 2:
            return !project.narrations.isEmpty
        default:
            return false
        }
    }

    private func clipWidth(for trackIndex: Int, timelineWidth: CGFloat) -> CGFloat {
        guard trackIndex != 0, let narration = project.narrations.first, model.duration > 0 else {
            return timelineWidth
        }

        let ratio = min(max(narration.duration / model.duration, 0.04), 1.0)
        return max(52, timelineWidth * CGFloat(ratio))
    }

    private func trackTitle(for trackIndex: Int) -> String {
        switch trackIndex {
        case 0:
            return model.selectedVideoURL?.lastPathComponent ?? "Video"
        case 1:
            return project.narrations.first?.url.lastPathComponent ?? "Narration"
        case 2:
            return project.narrations.first?.transcript ?? "Word subtitles"
        default:
            return "Clip"
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
