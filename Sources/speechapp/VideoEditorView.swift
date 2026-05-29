import SwiftUI
import AVFoundation
import AVKit
import AppKit
import UniformTypeIdentifiers

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
