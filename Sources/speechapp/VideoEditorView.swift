import SwiftUI
import AVFoundation
import AVKit
import AppKit
import UniformTypeIdentifiers

private struct TimelineAudioPlayer {
    let clipID: UUID
    let trackID: UUID
    let timelineStart: Double
    let duration: Double
    let baseVolume: Float
    let player: AVAudioPlayer
}

@MainActor
final class VideoEditorModel: ObservableObject {
    @Published var selectedVideoURL: URL?
    @Published var duration: Double = 0
    @Published var currentTime: Double = 0
    @Published var isPlaying = false
    @Published var statusMessage = "Import a video to begin arranging."
    @Published var isDropTargeted = false
    @Published var masterVolume: Double = 0.82

    let player = AVPlayer()
    private let supportedVideoExtensions = ["mp4", "mov", "m4v", "mkv", "webm"]
    private let supportedAudioExtensions = ["mp3", "aac", "m4a", "wav", "aiff", "aif"]
    private var narrationPlayers: [UUID: TimelineAudioPlayer] = [:]
    private var mediaPlayers: [UUID: TimelineAudioPlayer] = [:]
    private var tracks: [TrackDescriptor] = []
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

    func importAudio(completion: @escaping (URL, Double) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .audio,
            .mp3,
            .mpeg4Audio,
            .wav,
            .aiff
        ]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            do {
                let importedURL = try copyAudioIntoAppStorage(url)
                let duration = try await audioDuration(for: importedURL)
                completion(importedURL, duration)
            } catch {
                statusMessage = "Could not import audio: \(error.localizedDescription)"
            }
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
            stopTimelineAudio()
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
            stopTimelineAudio()
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
            stopTimelineAudio()
            player.replaceCurrentItem(with: nil)
            statusMessage = "Import a video to begin arranging."
            return
        }

        Task {
            await loadVideo(url)
        }
    }

    func loadProjectAudio(
        narrationClips: [NarrationClip],
        narrations: [ProjectNarration],
        mediaClips: [MediaClip],
        tracks: [TrackDescriptor],
        masterVolume: Double
    ) {
        self.tracks = tracks
        loadProjectNarrations(clips: narrationClips, narrations: narrations)
        loadProjectMediaClips(clips: mediaClips)
        updateTimelineAudioVolumes(masterVolume: masterVolume)
        syncTimelineAudio(to: currentTime, forceSeek: true)
    }

    func updateTimelineAudioVolumes(tracks: [TrackDescriptor], masterVolume: Double) {
        self.tracks = tracks
        updateTimelineAudioVolumes(masterVolume: masterVolume)
    }

    private func loadProjectNarrations(clips: [NarrationClip], narrations: [ProjectNarration]) {
        let validClipIDs = Set(clips.map(\.id))
        for clipID in narrationPlayers.keys where !validClipIDs.contains(clipID) {
            narrationPlayers[clipID]?.player.stop()
            narrationPlayers[clipID] = nil
        }

        for clip in clips {
            if let existing = narrationPlayers[clip.id],
               existing.timelineStart == clip.startTime,
               existing.duration == clip.duration {
                continue
            }

            narrationPlayers[clip.id]?.player.stop()
            guard let narration = narration(for: clip, in: narrations) else { continue }

            do {
                let audioPlayer = try AVAudioPlayer(contentsOf: narration.url)
                audioPlayer.prepareToPlay()
                audioPlayer.volume = 1
                narrationPlayers[clip.id] = TimelineAudioPlayer(
                    clipID: clip.id,
                    trackID: clip.trackId,
                    timelineStart: clip.startTime,
                    duration: min(audioPlayer.duration, max(clip.duration, 0)),
                    baseVolume: 1,
                    player: audioPlayer
                )
            } catch {
                statusMessage = "Could not load narration audio: \(error.localizedDescription)"
            }
        }
    }

    private func loadProjectMediaClips(clips: [MediaClip]) {
        let validClipIDs = Set(clips.map(\.id))
        for clipID in mediaPlayers.keys where !validClipIDs.contains(clipID) {
            mediaPlayers[clipID]?.player.stop()
            mediaPlayers[clipID] = nil
        }

        for clip in clips {
            if let existing = mediaPlayers[clip.id],
               existing.trackID == clip.trackId,
               existing.timelineStart == clip.startTime,
               existing.duration == clip.duration,
               existing.baseVolume == clip.volume {
                continue
            }

            mediaPlayers[clip.id]?.player.stop()
            do {
                let audioPlayer = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: clip.audioFilePath))
                audioPlayer.prepareToPlay()
                audioPlayer.volume = clip.volume
                mediaPlayers[clip.id] = TimelineAudioPlayer(
                    clipID: clip.id,
                    trackID: clip.trackId,
                    timelineStart: clip.startTime,
                    duration: min(audioPlayer.duration, max(clip.duration, 0)),
                    baseVolume: clip.volume,
                    player: audioPlayer
                )
            } catch {
                statusMessage = "Could not load audio clip: \(error.localizedDescription)"
            }
        }
    }

    func togglePlayback() {
        guard selectedVideoURL != nil else { return }

        if isPlaying {
            player.pause()
            pauseTimelineAudio()
            isPlaying = false
        } else {
            if duration > 0 && currentTime >= duration {
                seek(to: 0)
            }
            player.play()
            isPlaying = true
            syncTimelineAudio(to: currentTime, forceSeek: true)
        }
    }

    func jumpToStart() {
        seek(to: 0)
    }

    func jumpToEnd() {
        seek(to: duration)
    }

    func stepBackward(frameRate: Double = 30) {
        seek(to: currentTime - 1 / frameRate)
    }

    func stepForward(frameRate: Double = 30) {
        seek(to: currentTime + 1 / frameRate)
    }

    func seek(to seconds: Double) {
        let clamped = min(max(seconds, 0), duration)
        currentTime = clamped
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        syncTimelineAudio(to: clamped, forceSeek: true)
    }

    func syncCurrentTimeFromPlayer() {
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return }

        currentTime = min(max(seconds, 0), duration)
        syncTimelineAudio(to: currentTime, forceSeek: false)
        if isPlaying && duration > 0 && currentTime >= duration {
            stopTimelineAudio()
            isPlaying = false
        }
    }

    private func stop() {
        player.pause()
        pauseTimelineAudio()
        isPlaying = false
    }

    private func syncTimelineAudio(to seconds: Double, forceSeek: Bool) {
        for timelinePlayer in Array(narrationPlayers.values) + Array(mediaPlayers.values) {
            let audioPlayer = timelinePlayer.player
            guard let localTime = clipLocalTime(
                for: seconds,
                timelineStart: timelinePlayer.timelineStart,
                duration: timelinePlayer.duration
            ) else {
                if audioPlayer.isPlaying {
                    audioPlayer.pause()
                }
                if forceSeek {
                    audioPlayer.currentTime = seconds < timelinePlayer.timelineStart ? 0 : audioPlayer.duration
                }
                continue
            }

            if forceSeek || !audioPlayer.isPlaying {
                audioPlayer.currentTime = min(localTime, audioPlayer.duration)
            }
            if isPlaying && !audioPlayer.isPlaying {
                audioPlayer.play()
            }
        }
    }

    private func pauseTimelineAudio() {
        for timelinePlayer in Array(narrationPlayers.values) + Array(mediaPlayers.values) {
            timelinePlayer.player.pause()
        }
    }

    private func stopTimelineAudio() {
        for timelinePlayer in Array(narrationPlayers.values) + Array(mediaPlayers.values) {
            timelinePlayer.player.stop()
        }
    }

    private func updateTimelineAudioVolumes(masterVolume: Double) {
        let soloTrackIDs = Set(tracks.filter(\.solo).map(\.id))
        for timelinePlayer in Array(narrationPlayers.values) + Array(mediaPlayers.values) {
            let track = tracks.first { $0.id == timelinePlayer.trackID }
            let isAudibleBySolo = soloTrackIDs.isEmpty || soloTrackIDs.contains(timelinePlayer.trackID)
            let isMuted = track?.muted ?? false
            let trackVolume = track?.volume ?? 1
            timelinePlayer.player.volume = isMuted || !isAudibleBySolo ? 0 : timelinePlayer.baseVolume * trackVolume * Float(masterVolume)
        }
    }

    private func clipLocalTime(for timelineTime: Double, timelineStart: Double, duration: Double) -> Double? {
        let localTime = timelineTime - timelineStart
        guard localTime >= 0, localTime < duration else { return nil }
        return min(max(localTime, 0), duration)
    }

    private func narration(for clip: NarrationClip, in narrations: [ProjectNarration]) -> ProjectNarration? {
        narrations.first { narration in
            narration.url.path(percentEncoded: false) == clip.audioFilePath
        }
    }

    private func isSupportedVideo(_ url: URL) -> Bool {
        supportedVideoExtensions.contains(url.pathExtension.lowercased())
    }

    private func isSupportedAudio(_ url: URL) -> Bool {
        supportedAudioExtensions.contains(url.pathExtension.lowercased())
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

    private func copyAudioIntoAppStorage(_ sourceURL: URL) throws -> URL {
        guard isSupportedAudio(sourceURL) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }

        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let directory = try audioImportsDirectory()
        let destinationURL = uniqueImportedAudioURL(for: sourceURL, in: directory)

        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    private func audioDuration(for url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let loadedDuration = try await asset.load(.duration)
        let seconds = loadedDuration.seconds
        return seconds.isFinite ? max(seconds, 0.1) : 0.1
    }

    private func videoImportsDirectory() throws -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = root.appendingPathComponent("speechapp/VideoImports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func audioImportsDirectory() throws -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = root.appendingPathComponent("speechapp/AudioImports", isDirectory: true)
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

    private func uniqueImportedAudioURL(for sourceURL: URL, in directory: URL) -> URL {
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
    @State private var isRendering = false
    @State private var exportDiagnosticsLog = ""
    @State private var isShowingExportDiagnostics = false
    @State private var shouldReplaceNarrationOnPlace = false
    @State private var selectedNarrationClipID: UUID?
    private let playbackTimer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    private var activeNarrationClip: NarrationClip? {
        if let selectedNarrationClipID,
           let selectedClip = project.narrationClips.first(where: { $0.id == selectedNarrationClipID }) {
            return selectedClip
        }

        return project.narrationClips.sorted { $0.startTime < $1.startTime }.first
    }

    private var activePreviewNarrationClip: NarrationClip? {
        project.narrationClips
            .filter { model.currentTime >= $0.startTime && model.currentTime <= $0.endTime }
            .sorted { lhs, rhs in
                trackOrder(for: lhs.trackId) < trackOrder(for: rhs.trackId)
            }
            .first
    }

    private var activePreviewNarration: ProjectNarration? {
        guard let activePreviewNarrationClip else { return nil }
        return narration(for: activePreviewNarrationClip)
    }

    private var activePreviewNarrationLocalTime: Double? {
        guard let activePreviewNarrationClip else { return nil }
        let localTime = model.currentTime - activePreviewNarrationClip.startTime
        guard localTime >= 0, localTime <= activePreviewNarrationClip.duration else { return nil }
        return localTime
    }

    private var activeNarration: ProjectNarration? {
        guard let activeNarrationClip else { return project.narrations.first }
        return narration(for: activeNarrationClip) ?? project.narrations.first
    }

    private var activeNarrationLocalTime: Double? {
        guard let activeNarrationClip else { return model.currentTime }
        let localTime = model.currentTime - activeNarrationClip.startTime
        guard localTime >= 0, localTime <= activeNarrationClip.duration else { return nil }
        return localTime
    }

    var body: some View {
        VStack(spacing: 0) {
            editorTopBar

            Divider()

            HStack(spacing: 0) {
                previewSection
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                EditorInspectorPanel(
                    project: $project,
                    selectedNarrationClipID: selectedNarrationClipID,
                    isRendering: isRendering,
                    exportLog: exportDiagnosticsLog,
                    onExport: renderVideoWithSubtitles
                )
                    .frame(width: 360)
            }

            TimelineViewShell(
                model: model,
                project: $project,
                selectedNarrationClipID: $selectedNarrationClipID,
                onAddNarration: {
                    shouldReplaceNarrationOnPlace = false
                    isShowingNarration = true
                },
                onImportAudioClip: importAudioClip,
                onReplaceNarration: replaceNarrationFromTimeline,
                onDeleteNarration: deleteNarrationFromTimeline
            )
                .frame(minHeight: 260, idealHeight: 320)
        }
        .foregroundStyle(.primary)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $isShowingNarration) {
            SpeechNarrationView(onPlaceRecording: placeNarrationIntoTrack)
                .environmentObject(backend)
        }
        .sheet(isPresented: $isShowingExportDiagnostics) {
            ExportDiagnosticsView(log: exportDiagnosticsLog)
        }
        .onAppear {
            model.onVideoImported = { url in
                project.videoURL = url
            }
            model.player.isMuted = project.videoAudioMuted
            model.player.volume = project.videoAudioVolume * Float(model.masterVolume)
            model.loadProjectVideo(project.videoURL)
            loadProjectAudioIntoModel()
        }
        .onChange(of: project.videoURL) { _, newURL in
            model.loadProjectVideo(newURL)
        }
        .onChange(of: project.narrations) { _, _ in
            loadProjectAudioIntoModel()
        }
        .onChange(of: project.narrationClips) { _, _ in
            loadProjectAudioIntoModel()
        }
        .onChange(of: project.mediaClips) { _, _ in
            loadProjectAudioIntoModel()
        }
        .onChange(of: project.tracks) { _, _ in
            model.updateTimelineAudioVolumes(tracks: project.tracks, masterVolume: model.masterVolume)
        }
        .onReceive(playbackTimer) { _ in
            model.syncCurrentTimeFromPlayer()
        }
        .onChange(of: model.masterVolume) { _, newValue in
            model.player.volume = project.videoAudioVolume * Float(newValue)
            model.updateTimelineAudioVolumes(tracks: project.tracks, masterVolume: newValue)
        }
        .onChange(of: project.videoAudioMuted) { _, newValue in
            model.player.isMuted = newValue
        }
        .onChange(of: project.videoAudioVolume) { _, newValue in
            model.player.volume = newValue * Float(model.masterVolume)
        }
    }

    private var editorTopBar: some View {
        HStack(spacing: 16) {
            Button(action: onCloseProject) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .help("Back to projects")

            HStack(spacing: 8) {
                Text(project.name)
                    .font(.headline)
                    .lineLimit(1)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 7, height: 7)
            }
            .padding(.horizontal, 14)
            .frame(width: 260, height: 34, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(.separator.opacity(0.8))
            }

            Spacer()

            HStack(spacing: 24) {
                Button(action: model.jumpToStart) { Image(systemName: "backward.end.fill") }
                Button(action: { model.stepBackward() }) { Image(systemName: "backward.fill") }
                Button(action: model.togglePlayback) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 26)
                }
                Button(action: { model.stepForward() }) { Image(systemName: "forward.fill") }
                Button(action: model.jumpToEnd) { Image(systemName: "forward.end.fill") }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 28)
            .frame(height: 42)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.separator.opacity(0.7))
            }
            .disabled(model.selectedVideoURL == nil)

            Spacer()

            HStack(spacing: 10) {
                Image(systemName: "speaker.wave.2.fill")
                Slider(value: $model.masterVolume, in: 0...2)
                    .frame(width: 150)
                Text("\(Int((model.masterVolume * 100).rounded()))%")
                    .font(.system(.callout, design: .monospaced))
                    .frame(width: 44, alignment: .trailing)
            }

            Button(action: renderVideoWithSubtitles) {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(isRendering || project.videoURL == nil || project.narrationClips.isEmpty)
            .help(renderButtonHelp)

            if isRendering {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 20)
            } else {
                Image(systemName: "sparkle.magnifyingglass")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.bar)
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

                        if let activePreviewNarration, let activePreviewNarrationLocalTime {
                            SubtitlePreviewOverlay(
                                narration: activePreviewNarration,
                                currentTime: activePreviewNarrationLocalTime,
                                style: project.subtitleStyle,
                                previewSize: CGSize(width: previewWidth, height: previewHeight)
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
        if project.narrationClips.isEmpty {
            return "Generate and place narration before rendering."
        }
        return "Export video with generated narration and word-synced subtitles."
    }

    private func placeNarrationIntoTrack(_ narration: ProjectNarration) {
        if shouldReplaceNarrationOnPlace {
            project.audioURLs.removeAll { url in project.narrations.contains { $0.url == url } }
            project.narrations.removeAll()
            project.narrationClips.removeAll()
            shouldReplaceNarrationOnPlace = false
        }

        if !project.audioURLs.contains(narration.url) {
            project.audioURLs.append(narration.url)
        }

        project.narrations.append(narration)
        let narrationTrack = project.tracks.first(where: { $0.type == .narration }) ?? project.addTrack(type: .narration)
        var clip = NarrationClip(
            trackId: narrationTrack.id,
            startTime: model.currentTime,
            audioFilePath: narration.url.path(percentEncoded: false),
            text: narration.transcript,
            words: WordTiming.words(for: narration, style: project.subtitleStyle)
        )
        clip.startTime = project.autoNudgedStart(for: clip)
        project.addNarrationClip(clip)
        selectedNarrationClipID = clip.id
        loadProjectAudioIntoModel()
        renderMessage = "Narration placed at \(formatTimecode(clip.startTime))"
        isShowingNarration = false
    }

    private func replaceNarrationFromTimeline() {
        shouldReplaceNarrationOnPlace = true
        isShowingNarration = true
    }

    private func deleteNarrationFromTimeline() {
        let narrationURLs = Set(project.narrations.map(\.url))
        project.narrations.removeAll()
        project.narrationClips.removeAll()
        project.audioURLs.removeAll { narrationURLs.contains($0) }
        loadProjectAudioIntoModel()
        selectedNarrationClipID = nil
        renderMessage = "Removed narration from audio/subtitle tracks"
    }

    private func importAudioClip(for track: TrackDescriptor) {
        model.importAudio { importedURL, duration in
            let remainingProjectDuration = model.duration > model.currentTime ? model.duration - model.currentTime : duration
            let clip = MediaClip(
                id: UUID(),
                trackId: track.id,
                startTime: model.currentTime,
                duration: min(duration, max(0.1, remainingProjectDuration)),
                audioFilePath: importedURL.path(percentEncoded: false),
                volume: track.type == .music ? 0.7 : 1.0,
                fadeInDuration: 0,
                fadeOutDuration: 0,
                loop: false
            )
            project.mediaClips.append(clip)
            loadProjectAudioIntoModel()
            renderMessage = "Imported \(importedURL.lastPathComponent)"
        }
    }

    private func loadProjectAudioIntoModel() {
        model.loadProjectAudio(
            narrationClips: project.narrationClips,
            narrations: project.narrations,
            mediaClips: project.mediaClips,
            tracks: project.tracks,
            masterVolume: model.masterVolume
        )
    }

    private func narration(for clip: NarrationClip) -> ProjectNarration? {
        project.narrations.first { narration in
            narration.url.path(percentEncoded: false) == clip.audioFilePath
        }
    }

    private func trackOrder(for trackID: UUID) -> Int {
        project.tracks.first(where: { $0.id == trackID })?.order ?? Int.max
    }

    private func renderVideoWithSubtitles() {
        guard let videoURL = project.videoURL else {
            renderMessage = "Import a video before rendering"
            return
        }

        guard let narration = activeNarration, !project.narrationClips.isEmpty else {
            renderMessage = "Generate and place narration before rendering"
            return
        }

        guard let outputURL = chooseRenderOutputURL() else { return }

        isRendering = true
        renderMessage = "Rendering video..."

        Task {
            do {
                let result = try await SwiftFFmpegRunner.exportVideoWithSubtitles(VideoExportRequest(
                    videoURL: videoURL,
                    narration: narration,
                    subtitleStyle: project.subtitleStyle,
                    outputURL: outputURL
                ))

                await MainActor.run {
                    isRendering = false
                    renderMessage = "Exported \(result.outputURL.lastPathComponent)"
                    exportDiagnosticsLog = result.ffmpegLog
                    NSWorkspace.shared.activateFileViewerSelecting([result.outputURL])
                }
            } catch {
                await MainActor.run {
                    isRendering = false
                    renderMessage = error.localizedDescription
                    exportDiagnosticsLog = exportLog(from: error)
                    isShowingExportDiagnostics = true
                }
            }
        }
    }

    private func chooseRenderOutputURL() -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Video"
        panel.nameFieldStringValue = "\(project.name)-subtitled.mp4"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.mpeg4Movie]
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func exportLog(from error: Error) -> String {
        if case VideoExportError.processFailed(let log) = error {
            return log
        }

        return error.localizedDescription
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

private extension Color {
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

struct TimelineViewShell: View {
    @ObservedObject var model: VideoEditorModel
    @Binding var project: SpeechAppProject
    @Binding var selectedNarrationClipID: UUID?
    let onAddNarration: () -> Void
    let onImportAudioClip: (TrackDescriptor) -> Void
    let onReplaceNarration: () -> Void
    let onDeleteNarration: () -> Void

    private let labelColumnWidth: CGFloat = 248
    private let rulerHeight: CGFloat = 28
    private let trackHeight: CGFloat = 56
    @State private var trackPendingDeletion: TrackDescriptor?
    @State private var dragStartTimes: [UUID: Double] = [:]
    @State private var dragPreviewStartTimes: [UUID: Double] = [:]
    @State private var isDraggingClip = false

    var body: some View {
        VStack(spacing: 0) {
            timelineToolbar
                .frame(height: 48)
            Divider()
            GeometryReader { proxy in
                let timelineWidth = max(proxy.size.width - labelColumnWidth, 1)
                let canvasHeight = rulerHeight + trackHeight * CGFloat(project.tracks.count)
                let progress = progressValue
                let playheadX = labelColumnWidth + timelineWidth * progress

                ZStack(alignment: .topLeading) {
                    timelineBackground

                    VStack(spacing: 0) {
                        ruler(timelineWidth: timelineWidth)
                            .frame(height: rulerHeight)

                        ForEach(project.tracks.sorted(by: { $0.order < $1.order })) { track in
                            trackRow(track, timelineWidth: timelineWidth)
                                .frame(height: trackHeight)
                        }
                    }

                    playhead
                        .position(x: playheadX, y: canvasHeight / 2)
                }
                .onHover { isHovering in
                    if isHovering {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Delete Track", isPresented: deleteTrackAlertBinding, presenting: trackPendingDeletion) { track in
            Button("Cancel", role: .cancel) {
                trackPendingDeletion = nil
            }
            Button("Delete Track", role: .destructive) {
                project.deleteTrack(id: track.id)
                if let selectedNarrationClipID,
                   !project.narrationClips.contains(where: { $0.id == selectedNarrationClipID }) {
                    self.selectedNarrationClipID = nil
                }
                trackPendingDeletion = nil
            }
        } message: { track in
            Text("Delete this track and all \(clipCount(for: track)) clips on it? This cannot be undone.")
        }
    }

    private var timelineToolbar: some View {
        HStack(spacing: 12) {
            Menu {
                Button("Add Narration Track") { _ = project.addTrack(type: .narration) }
                Button("Add Music Track") { _ = project.addTrack(type: .music) }
                Button("Add Sound FX Track") { _ = project.addTrack(type: .sfx) }
                Button("Add Subtitle Override Track") { _ = project.addTrack(type: .subtitleOverride) }
            } label: {
                Label("Add Track", systemImage: "plus")
            }
            .menuStyle(.button)

            Button(action: onAddNarration) {
                Label("Add Narration", systemImage: "mic.badge.plus")
            }

            HStack(spacing: 10) {
                Button(action: {}) { Image(systemName: "scissors") }
                Button(action: {}) { Image(systemName: "doc.on.doc") }
                Button(role: .destructive, action: onDeleteNarration) { Image(systemName: "trash") }
            }
            .buttonStyle(.borderless)

            if overlapCount > 0 {
                Label("\(overlapCount) Overlap Warning", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }

            Spacer()

            Text("Project Duration: \(formatTimecode(model.duration))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("30 fps")
                .font(.caption)
                .foregroundStyle(.secondary)
            Image(systemName: "minus.magnifyingglass")
            Slider(value: .constant(0.44), in: 0...1)
                .frame(width: 110)
            Image(systemName: "plus.magnifyingglass")
        }
        .padding(.horizontal, 18)
    }

    private var timelineBackground: some View {
        Rectangle()
            .fill(Color(nsColor: .textBackgroundColor))
    }

    private func ruler(timelineWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .frame(width: labelColumnWidth)

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color(nsColor: .windowBackgroundColor))

                ForEach(rulerTicks(timelineWidth: timelineWidth), id: \.self) { second in
                    let x = tickX(second: second, width: timelineWidth)
                    VStack(spacing: 3) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.42))
                            .frame(width: 1, height: 12)
                        Text(formatTimelineTick(second))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .position(x: x, y: 17)
                }
            }
            .frame(width: timelineWidth)
            .contentShape(Rectangle())
            .onTapGesture { location in
                seek(canvasX: location.x, timelineWidth: timelineWidth)
            }
        }
    }

    private func trackRow(_ track: TrackDescriptor, timelineWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            TrackHeaderView(
                track: binding(for: track),
                videoAudioMuted: $project.videoAudioMuted,
                videoAudioVolume: $project.videoAudioVolume,
                onSolo: { isSolo in
                    project.setTrackSolo(id: track.id, isSolo: isSolo)
                },
                onDelete: {
                    trackPendingDeletion = track
                }
            )
                .frame(width: labelColumnWidth)

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(track.type == .video ? Color.blue.opacity(0.04) : Color(nsColor: .textBackgroundColor))

                switch track.type {
                case .video:
                    if model.selectedVideoURL != nil {
                        videoClip(track: track, timelineWidth: timelineWidth)
                    }
                case .narration:
                    ForEach(project.narrationClips.filter { $0.trackId == track.id }) { clip in
                        narrationClip(clip, track: track, timelineWidth: timelineWidth)
                    }
                case .music, .sfx:
                    let clips = project.mediaClips.filter { $0.trackId == track.id }
                    if clips.isEmpty {
                        mediaPlaceholder(track: track, timelineWidth: timelineWidth)
                            .onTapGesture {
                                onImportAudioClip(track)
                            }
                    } else {
                        ForEach(clips) { clip in
                            mediaClip(clip, track: track, timelineWidth: timelineWidth)
                        }
                    }
                case .subtitleOverride:
                    subtitleOverridePlaceholder(track: track, timelineWidth: timelineWidth)
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.16))
                    .frame(height: 1)
            }
            .frame(width: timelineWidth)
            .contentShape(Rectangle())
            .onTapGesture { location in
                seek(canvasX: location.x, timelineWidth: timelineWidth)
            }
        }
    }

    private func videoClip(track: TrackDescriptor, timelineWidth: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(hex: track.colour).opacity(0.82))
            .frame(width: timelineWidth - 12, height: 42)
            .overlay(alignment: .leading) {
                HStack(spacing: 3) {
                    ForEach(0..<28, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(index.isMultiple(of: 2) ? .white.opacity(0.26) : .black.opacity(0.10))
                            .frame(width: 22, height: 30)
                    }
                    Spacer()
                    Text(model.selectedVideoURL?.lastPathComponent ?? "Video")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.trailing, 10)
                }
                .padding(.leading, 8)
            }
            .padding(.leading, 10)
    }

    private func narrationClip(_ clip: NarrationClip, track: TrackDescriptor, timelineWidth: CGFloat) -> some View {
        let originalX = xPosition(for: clip.startTime, width: timelineWidth)
        let previewStartTime = dragPreviewStartTimes[clip.id]
        let previewClip = clip.withStartTime(previewStartTime ?? clip.startTime)
        let previewX = previewStartTime.map { xPosition(for: $0, width: timelineWidth) }
        let width = max(96, durationWidth(clip.duration, width: timelineWidth))

        return ZStack(alignment: .leading) {
            narrationClipBlock(
                clip: clip,
                track: track,
                width: width,
                isSelected: selectedNarrationClipID == clip.id,
                hasOverlap: !project.narrationOverlaps(for: clip).isEmpty
            )
            .opacity(previewStartTime == nil ? 1 : 0.32)
            .offset(x: originalX)
            .onTapGesture {
                selectedNarrationClipID = clip.id
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        guard !track.locked else { return }
                        if dragStartTimes[clip.id] == nil {
                            dragStartTimes[clip.id] = clip.startTime
                            selectedNarrationClipID = clip.id
                            isDraggingClip = true
                        }
                        let secondsDelta = Double(value.translation.width / timelineWidth) * max(model.duration, clip.duration, 1)
                        let proposed = (dragStartTimes[clip.id] ?? clip.startTime) + secondsDelta
                        dragPreviewStartTimes[clip.id] = clampedStartTime(proposed, for: clip)
                    }
                    .onEnded { _ in
                        if let previewStartTime = dragPreviewStartTimes[clip.id] {
                            let committedStartTime = snappedStartTime(previewStartTime, for: clip)
                            project.moveNarrationClip(id: clip.id, to: committedStartTime)
                        }
                        dragStartTimes[clip.id] = nil
                        dragPreviewStartTimes[clip.id] = nil
                        isDraggingClip = false
                    }
            )

            if let previewX {
                narrationClipBlock(
                    clip: clip,
                    track: track,
                    width: width,
                    isSelected: true,
                    hasOverlap: !project.narrationOverlaps(for: previewClip).isEmpty
                )
                .opacity(0.82)
                .offset(x: previewX)
                .allowsHitTesting(false)
            }
        }
        .frame(width: timelineWidth, height: 42, alignment: .leading)
        .contextMenu {
                Button("Play Clip") {
                    model.seek(to: clip.startTime)
                    model.togglePlayback()
                }
                Button("Replace Audio", action: onReplaceNarration)
                Button(role: .destructive, action: { project.deleteNarrationClip(id: clip.id) }) {
                    Text("Delete Clip")
                }
        }
        .animation(nil, value: previewStartTime)
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private func narrationClipBlock(
        clip: NarrationClip,
        track: TrackDescriptor,
        width: CGFloat,
        isSelected: Bool,
        hasOverlap: Bool
    ) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(hex: track.colour).opacity(0.78))
            .frame(width: width, height: 42)
            .overlay(alignment: .topLeading) {
                Text(clip.text.isEmpty ? "Narration" : clip.text)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color(hex: track.colour))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: width - 24, alignment: .leading)
                    .background(.white, in: Capsule())
                    .padding(8)
            }
            .overlay(alignment: .bottom) {
                WaveformStrip(color: .white.opacity(0.52))
                    .frame(height: 14)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 5)
            }
            .overlay {
                if hasOverlap {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.orange, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                } else if isSelected {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.white, lineWidth: 2)
                }
            }
    }

    private func mediaPlaceholder(track: TrackDescriptor, timelineWidth: CGFloat) -> some View {
        let sampleWidth = min(timelineWidth * 0.72, 760)
        return RoundedRectangle(cornerRadius: 6)
            .fill(Color(hex: track.colour).opacity(track.muted ? 0.18 : 0.34))
            .frame(width: sampleWidth, height: 32)
            .overlay {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle")
                    Text("Click to import audio")
                    WaveformStrip(color: Color(hex: track.colour).opacity(0.5))
                        .frame(maxWidth: .infinity)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(Color(hex: track.colour).opacity(0.85))
                .padding(.horizontal, 10)
            }
            .padding(.leading, 64)
            .opacity(track.muted ? 0.65 : 1)
    }

    private func mediaClip(_ clip: MediaClip, track: TrackDescriptor, timelineWidth: CGFloat) -> some View {
        let x = xPosition(for: clip.startTime, width: timelineWidth)
        let width = max(80, durationWidth(clip.duration, width: timelineWidth))
        let title = URL(fileURLWithPath: clip.audioFilePath).lastPathComponent

        return RoundedRectangle(cornerRadius: 6)
            .fill(Color(hex: track.colour).opacity(track.muted ? 0.28 : 0.64))
            .frame(width: width, height: 36)
            .overlay(alignment: .leading) {
                HStack(spacing: 8) {
                    WaveformStrip(color: .white.opacity(0.42))
                        .frame(width: max(24, width * 0.45))
                    Text(title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
            }
            .contextMenu {
                Button("Rename Clip") {}
                Button("Trim to Playhead") {
                    trimMediaClipToPlayhead(clip)
                }
                Button(role: .destructive) {
                    project.mediaClips.removeAll { $0.id == clip.id }
                } label: {
                    Text("Delete Clip")
                }
            }
            .offset(x: x)
    }

    private func subtitleOverridePlaceholder(track: TrackDescriptor, timelineWidth: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(hex: track.colour).opacity(0.55))
            .frame(width: min(timelineWidth * 0.38, 420), height: 34)
            .overlay(alignment: .leading) {
                Label("Custom subtitle for emphasis", systemImage: "captions.bubble")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
            }
            .padding(.leading, 84)
    }

    private func binding(for track: TrackDescriptor) -> Binding<TrackDescriptor> {
        Binding(
            get: { project.tracks.first(where: { $0.id == track.id }) ?? track },
            set: { updatedTrack in
                guard let index = project.tracks.firstIndex(where: { $0.id == updatedTrack.id }) else { return }
                project.tracks[index] = updatedTrack
            }
        )
    }

    private func trimMediaClipToPlayhead(_ clip: MediaClip) {
        guard model.currentTime > clip.startTime,
              model.currentTime < clip.endTime,
              let index = project.mediaClips.firstIndex(where: { $0.id == clip.id })
        else {
            return
        }

        project.mediaClips[index].duration = model.currentTime - clip.startTime
    }

    private var overlapCount: Int {
        project.narrationClips.reduce(0) { count, clip in
            count + (project.narrationOverlaps(for: clip).isEmpty ? 0 : 1)
        }
    }

    private var deleteTrackAlertBinding: Binding<Bool> {
        Binding(
            get: { trackPendingDeletion != nil },
            set: { if !$0 { trackPendingDeletion = nil } }
        )
    }

    private func clipCount(for track: TrackDescriptor) -> Int {
        project.narrationClips.filter { $0.trackId == track.id }.count +
        project.mediaClips.filter { $0.trackId == track.id }.count
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

    private func rulerTicks(timelineWidth: CGFloat) -> [Double] {
        let duration = max(model.duration, 1)
        let targetTickCount = max(2, Int(timelineWidth / 96))
        let rawStep = duration / Double(targetTickCount)
        let step = niceTickStep(for: rawStep)
        let maxTick = Int(ceil(duration / step))
        return (0...maxTick).map { Double($0) * step }.filter { $0 <= duration + step * 0.25 }
    }

    private func tickX(second: Double, width: CGFloat) -> CGFloat {
        let total = max(model.duration, 1)
        return width * CGFloat(second / total)
    }

    private func niceTickStep(for rawStep: Double) -> Double {
        let candidates: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        return candidates.first { $0 >= rawStep } ?? 900
    }

    private func xPosition(for seconds: Double, width: CGFloat) -> CGFloat {
        let total = max(model.duration, 1)
        return width * CGFloat(seconds / total)
    }

    private func durationWidth(_ duration: Double, width: CGFloat) -> CGFloat {
        let total = max(model.duration, duration, 1)
        return width * CGFloat(duration / total)
    }

    private func snappedStartTime(_ proposedStart: Double, for clip: NarrationClip) -> Double {
        let duration = max(model.duration, clip.duration, 1)
        let snapSeconds = duration * 0.004
        var candidates = [0, model.currentTime]
        candidates.append(contentsOf: project.narrationClips
            .filter { $0.id != clip.id && $0.trackId == clip.trackId }
            .flatMap { [$0.startTime, $0.endTime] })

        guard let nearest = candidates.min(by: { abs($0 - proposedStart) < abs($1 - proposedStart) }),
              abs(nearest - proposedStart) <= snapSeconds
        else {
            return max(0, min(proposedStart, duration))
        }

        return max(0, min(nearest, duration))
    }

    private func clampedStartTime(_ proposedStart: Double, for clip: NarrationClip) -> Double {
        max(0, min(proposedStart, max(model.duration, clip.duration, 1)))
    }

    private func seek(canvasX: CGFloat, timelineWidth: CGFloat) {
        guard model.duration > 0 else { return }
        guard !isDraggingClip else { return }
        let localX = min(max(canvasX, 0), timelineWidth)
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

private func formatTimecode(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "00:00.00" }

    let centiseconds = max(Int((seconds * 100).rounded()), 0)
    let minutes = centiseconds / 6_000
    let remainingCentiseconds = centiseconds % 6_000
    let wholeSeconds = remainingCentiseconds / 100
    let fraction = remainingCentiseconds % 100
    return String(format: "%02d:%02d.%02d", minutes, wholeSeconds, fraction)
}

private func formatTimelineTick(_ seconds: Double) -> String {
    formatTimecode(seconds)
}
