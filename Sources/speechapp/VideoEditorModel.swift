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
