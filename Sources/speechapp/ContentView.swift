import SwiftUI
import AVFAudio
import AppKit
import UniformTypeIdentifiers

final class PCMStreamPlayer {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var pendingData = Data()
    private let scheduleBatchFrames = 2048
    private let initialBufferedFrames: AVAudioFramePosition
    private var queuedFrames: AVAudioFramePosition = 0
    private var isPrepared = false
    private var hasStartedPlayback = false

    init(sampleRate: Double = 24_000, initialBufferSeconds: Double = 0.75) {
        self.format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        self.initialBufferedFrames = AVAudioFramePosition(sampleRate * initialBufferSeconds)
    }

    func start() throws {
        if !isPrepared {
            engine.attach(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: format)
            isPrepared = true
        }

        if !engine.isRunning {
            try engine.start()
        }
    }

    func append(_ data: Data, flush: Bool = false) throws {
        pendingData.append(data)

        let bytesPerFrame = MemoryLayout<Int16>.size
        let completeFrameCount = pendingData.count / bytesPerFrame
        guard completeFrameCount > 0 else { return }

        if !flush && completeFrameCount < scheduleBatchFrames {
            return
        }

        let bytesToSchedule = completeFrameCount * bytesPerFrame
        let schedulableData = pendingData.prefix(bytesToSchedule)
        pendingData.removeFirst(bytesToSchedule)

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(completeFrameCount)
        ) else {
            return
        }

        buffer.frameLength = AVAudioFrameCount(completeFrameCount)

        schedulableData.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            let output = buffer.floatChannelData![0]

            for index in 0..<completeFrameCount {
                output[index] = Float(samples[index]) / Float(Int16.max)
            }
        }

        queuedFrames += AVAudioFramePosition(completeFrameCount)
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
        startPlaybackIfReady(force: flush)
    }

    func finish() throws {
        try append(Data(), flush: true)
        startPlaybackIfReady(force: true)
    }

    func stop() {
        playerNode.stop()
        engine.stop()
        pendingData.removeAll(keepingCapacity: true)
        queuedFrames = 0
        hasStartedPlayback = false
    }

    private func startPlaybackIfReady(force: Bool) {
        guard !hasStartedPlayback else { return }
        guard force || queuedFrames >= initialBufferedFrames else { return }

        playerNode.play()
        hasStartedPlayback = true
    }
}

struct SavedRecording: Identifiable, Hashable {
    let url: URL
    let createdAt: Date
    let byteCount: Int64

    var id: URL { url }
    var title: String { url.deletingPathExtension().lastPathComponent }
}

struct WaveformPreview: View {
    let seed: String
    let isActive: Bool

    private let barCount = 54

    var body: some View {
        GeometryReader { proxy in
            let bars = waveformBars
            let spacing: CGFloat = 3
            let width = max(2, (proxy.size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))
            let midY = proxy.size.height / 2

            Canvas { context, size in
                var centerLine = Path()
                centerLine.move(to: CGPoint(x: 0, y: midY))
                centerLine.addLine(to: CGPoint(x: size.width, y: midY))
                context.stroke(centerLine, with: .color(.secondary.opacity(0.25)), lineWidth: 1)

                for index in 0..<barCount {
                    let x = CGFloat(index) * (width + spacing)
                    let normalized = bars[index]
                    let height = max(4, normalized * (size.height - 10))
                    let rect = CGRect(
                        x: x,
                        y: midY - height / 2,
                        width: width,
                        height: height
                    )
                    let path = Path(roundedRect: rect, cornerRadius: width / 2)
                    context.fill(path, with: .color(isActive ? .accentColor : Color.orange))
                }
            }
        }
        .background(Color.secondary.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Generated narration waveform preview")
    }

    private var waveformBars: [CGFloat] {
        var state = UInt64(seed.unicodeScalars.reduce(0) { ($0 &* 31) &+ UInt64($1.value) })
        return (0..<barCount).map { index in
            state = state &* 1_664_525 &+ 1_013_904_223 &+ UInt64(index)
            let random = CGFloat(state % 1_000) / 1_000
            let envelope = sin((CGFloat(index) / CGFloat(barCount - 1)) * .pi)
            return 0.18 + (0.28 + random * 0.54) * envelope
        }
    }
}

enum OperationStatus {
    case ready
    case busy
    case error
}

final class AudioPlaybackObserver: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }
}

struct SpeechAppProject: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var videoURL: URL?
    var audioURLs: [URL]
    var narrations: [ProjectNarration]
    var subtitleStyle: SubtitleStyleSettings

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.updatedAt = Date()
        self.videoURL = nil
        self.audioURLs = []
        self.narrations = []
        self.subtitleStyle = SubtitleStyleSettings()
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case createdAt
        case updatedAt
        case videoURL
        case audioURLs
        case narrations
        case subtitleStyle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.videoURL = try container.decodeIfPresent(URL.self, forKey: .videoURL)
        self.audioURLs = try container.decodeIfPresent([URL].self, forKey: .audioURLs) ?? []
        self.narrations = try container.decodeIfPresent([ProjectNarration].self, forKey: .narrations) ?? []
        self.subtitleStyle = try container.decodeIfPresent(SubtitleStyleSettings.self, forKey: .subtitleStyle) ?? SubtitleStyleSettings()
    }
}

struct SubtitleStyleSettings: Codable, Hashable {
    var isWordHighlightingEnabled: Bool
    var timingMode: SubtitleTimingMode
    var fontSize: Double
    var activeWordColorHex: String
    var textColorHex: String
    var outlineColorHex: String
    var timingOffset: Double
    var bottomMargin: Double
    var maxWordsPerLine: Int

    init(
        isWordHighlightingEnabled: Bool = true,
        timingMode: SubtitleTimingMode = .punctuationAware,
        fontSize: Double = 54,
        activeWordColorHex: String = "#FFD84D",
        textColorHex: String = "#FFFFFF",
        outlineColorHex: String = "#000000",
        timingOffset: Double = 0,
        bottomMargin: Double = 58,
        maxWordsPerLine: Int = 6
    ) {
        self.isWordHighlightingEnabled = isWordHighlightingEnabled
        self.timingMode = timingMode
        self.fontSize = fontSize
        self.activeWordColorHex = activeWordColorHex
        self.textColorHex = textColorHex
        self.outlineColorHex = outlineColorHex
        self.timingOffset = timingOffset
        self.bottomMargin = bottomMargin
        self.maxWordsPerLine = maxWordsPerLine
    }

    enum CodingKeys: String, CodingKey {
        case isWordHighlightingEnabled
        case timingMode
        case fontSize
        case activeWordColorHex
        case textColorHex
        case outlineColorHex
        case timingOffset
        case bottomMargin
        case maxWordsPerLine
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isWordHighlightingEnabled = try container.decodeIfPresent(Bool.self, forKey: .isWordHighlightingEnabled) ?? true
        let timingModeRawValue = try container.decodeIfPresent(String.self, forKey: .timingMode)
        self.timingMode = timingModeRawValue.flatMap(SubtitleTimingMode.init(rawValue:)) ?? .punctuationAware
        self.fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 54
        self.activeWordColorHex = try container.decodeIfPresent(String.self, forKey: .activeWordColorHex) ?? "#FFD84D"
        self.textColorHex = try container.decodeIfPresent(String.self, forKey: .textColorHex) ?? "#FFFFFF"
        self.outlineColorHex = try container.decodeIfPresent(String.self, forKey: .outlineColorHex) ?? "#000000"
        self.timingOffset = try container.decodeIfPresent(Double.self, forKey: .timingOffset) ?? 0
        self.bottomMargin = try container.decodeIfPresent(Double.self, forKey: .bottomMargin) ?? 58
        self.maxWordsPerLine = try container.decodeIfPresent(Int.self, forKey: .maxWordsPerLine) ?? 6
    }
}

enum SubtitleTimingMode: String, Codable, CaseIterable, Identifiable {
    case simple
    case punctuationAware

    var id: String { rawValue }

    var title: String {
        switch self {
        case .simple:
            "Simple"
        case .punctuationAware:
            "Smart"
        }
    }
}

struct ProjectNarration: Codable, Identifiable, Hashable {
    var id: UUID
    var url: URL
    var transcript: String
    var voice: String
    var createdAt: Date
    var duration: Double

    init(url: URL, transcript: String, voice: String, duration: Double) {
        self.id = UUID()
        self.url = url
        self.transcript = transcript
        self.voice = voice
        self.createdAt = Date()
        self.duration = duration
    }
}

struct RecentProject: Codable, Identifiable, Hashable {
    let url: URL
    let lastOpenedAt: Date

    var id: URL { url }
    var title: String { url.deletingPathExtension().lastPathComponent }
    var location: String { url.deletingLastPathComponent().path(percentEncoded: false) }
}

enum ProjectFileStore {
    static let fileExtension = "speechproj"
    private static let recentProjectsKey = "recentProjects"

    @MainActor
    static func createProject() throws -> (SpeechAppProject, URL)? {
        let panel = NSSavePanel()
        panel.title = "Create New Project"
        panel.nameFieldStringValue = "Untitled.\(fileExtension)"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .json]

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        let project = SpeechAppProject(name: url.deletingPathExtension().lastPathComponent)
        try save(project, to: url)
        addRecentProject(url)
        return (project, url)
    }

    static func loadProject(from url: URL) throws -> SpeechAppProject {
        let data = try Data(contentsOf: url)
        let project = try JSONDecoder.projectDecoder.decode(SpeechAppProject.self, from: data)
        addRecentProject(url)
        return project
    }

    static func save(_ project: SpeechAppProject, to url: URL) throws {
        var projectToSave = project
        projectToSave.updatedAt = Date()
        let data = try JSONEncoder.projectEncoder.encode(projectToSave)
        try data.write(to: url, options: .atomic)
    }

    static func addRecentProject(_ url: URL) {
        var projects = recentProjects().filter { $0.url != url }
        projects.insert(RecentProject(url: url, lastOpenedAt: Date()), at: 0)
        if projects.count > 12 {
            projects = Array(projects.prefix(12))
        }

        guard let data = try? JSONEncoder.projectEncoder.encode(projects) else { return }
        UserDefaults.standard.set(data, forKey: recentProjectsKey)
    }

    static func recentProjects() -> [RecentProject] {
        guard let data = UserDefaults.standard.data(forKey: recentProjectsKey),
              let projects = try? JSONDecoder.projectDecoder.decode([RecentProject].self, from: data)
        else {
            return []
        }

        return projects
            .filter { FileManager.default.fileExists(atPath: $0.url.path(percentEncoded: false)) }
            .sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }
}

private extension JSONEncoder {
    static var projectEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var projectDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

struct ContentView: View {
    @EnvironmentObject var backend: BackendProcessManager

    @State private var currentProject: SpeechAppProject?
    @State private var currentProjectURL: URL?
    @State private var recentProjects: [RecentProject] = []
    @State private var projectErrorMessage = ""
    @State private var isShowingHelp = false

    var body: some View {
        ZStack {
            if let project = currentProject, let projectURL = currentProjectURL {
                VideoEditorView(
                    project: binding(for: project),
                    projectURL: projectURL,
                    onCloseProject: closeProject
                )
                .frame(minWidth: 980, idealWidth: 1100, minHeight: 700, idealHeight: 760)
            } else {
                launchView
                    .frame(minWidth: 760, idealWidth: 860, minHeight: 440, idealHeight: 520)
            }
        }
        .onAppear {
            recentProjects = ProjectFileStore.recentProjects()
        }
        .alert("Help", isPresented: $isShowingHelp) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Create or open a project, import a video, then use Add Narration to generate local Kokoro voiceover audio. Subtitle styling, word syncing, and FFmpeg burn-in will be added in later milestones.")
        }
    }

    private func binding(for project: SpeechAppProject) -> Binding<SpeechAppProject> {
        Binding(
            get: { currentProject ?? project },
            set: { newValue in
                currentProject = newValue
                saveCurrentProject()
            }
        )
    }

    private var launchView: some View {
        HStack(spacing: 0) {
            VStack(spacing: 28) {
                Spacer()

                VStack(spacing: 14) {
                    placeholderAppIcon

                    VStack(spacing: 4) {
                        Text("Speech Studio")
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                        Text("Version \(appVersion)")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(spacing: 10) {
                    Button(action: createNewProject) {
                        Label("Create New Project", systemImage: "plus.square")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(LaunchButtonStyle())

                    Button(action: { isShowingHelp = true }) {
                        Label("Help", systemImage: "questionmark.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(LaunchButtonStyle())
                }
                .frame(width: 360)

                if !projectErrorMessage.isEmpty {
                    Text(projectErrorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .frame(width: 420)
                } else {
                    Text(backend.isServerReady ? "Local voice engine ready" : backend.initializationMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(34)

            recentProjectsSidebar
                .frame(width: 310)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var placeholderAppIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(LinearGradient(
                    colors: [
                        Color(red: 0.10, green: 0.58, blue: 0.95),
                        Color(red: 0.06, green: 0.23, blue: 0.68)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))

            Image(systemName: "waveform.and.person.filled")
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 116, height: 116)
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
    }

    private var recentProjectsSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Previous Projects")
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 22)

            if recentProjects.isEmpty {
                ContentUnavailableView(
                    "No Recent Projects",
                    systemImage: "clock",
                    description: Text("Saved projects will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(recentProjects) { project in
                    Button(action: { openRecentProject(project) }) {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.badge.gearshape")
                                .font(.system(size: 28))
                                .foregroundStyle(.blue)
                                .frame(width: 34)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.title)
                                    .font(.headline)
                                    .lineLimit(1)
                                Text(project.location)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .background(.bar)
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        if let version, let build, version != build {
            return "\(version) (\(build))"
        }

        return version ?? build ?? "0.1"
    }

    private func createNewProject() {
        do {
            guard let (project, url) = try ProjectFileStore.createProject() else { return }
            projectErrorMessage = ""
            currentProject = project
            currentProjectURL = url
            recentProjects = ProjectFileStore.recentProjects()
        } catch {
            projectErrorMessage = "Could not create project: \(error.localizedDescription)"
        }
    }

    private func openRecentProject(_ recentProject: RecentProject) {
        do {
            currentProject = try ProjectFileStore.loadProject(from: recentProject.url)
            currentProjectURL = recentProject.url
            projectErrorMessage = ""
            recentProjects = ProjectFileStore.recentProjects()
        } catch {
            projectErrorMessage = "Could not open project: \(error.localizedDescription)"
            recentProjects = ProjectFileStore.recentProjects()
        }
    }

    private func saveCurrentProject() {
        guard let currentProject, let currentProjectURL else { return }

        do {
            try ProjectFileStore.save(currentProject, to: currentProjectURL)
            ProjectFileStore.addRecentProject(currentProjectURL)
            recentProjects = ProjectFileStore.recentProjects()
            projectErrorMessage = ""
        } catch {
            projectErrorMessage = "Could not save project: \(error.localizedDescription)"
        }
    }

    private func closeProject() {
        saveCurrentProject()
        currentProject = nil
        currentProjectURL = nil
        recentProjects = ProjectFileStore.recentProjects()
    }
}

struct LaunchButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.semibold))
            .padding(.horizontal, 18)
            .frame(height: 54)
            .background(Color(nsColor: .controlBackgroundColor).opacity(configuration.isPressed ? 0.78 : 1), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.separator.opacity(0.6))
            }
    }
}

struct SpeechNarrationView: View {
    @EnvironmentObject var backend: BackendProcessManager
    @Environment(\.dismiss) private var dismiss
    var onPlaceRecording: ((ProjectNarration) -> Void)?

    @State private var textInput = "Hello! I am now streaming audio dynamically chunk by chunk."
    @State private var statusMessage = ""
    @State private var statusKind: OperationStatus = .ready
    @State private var selectedVoice = "af_heart"
    @State private var streamTask: Task<Void, Never>?
    @State private var fileTask: Task<Void, Never>?
    @State private var isStreaming = false
    @State private var isGeneratingFile = false
    @State private var isGeneratingTrackPlacement = false
    @State private var streamPlayer: PCMStreamPlayer?
    @State private var savedRecordings: [SavedRecording] = []
    @State private var filePlayer: AVAudioPlayer?
    @State private var previewPlayer: AVAudioPlayer?
    @State private var playbackObserver: AudioPlaybackObserver?
    @State private var playingRecordingID: URL?
    @State private var previewingVoice: String?
    @State private var isShowingVoicePicker = false
    @State private var pendingNarration: ProjectNarration?
    @State private var isPlayingGeneratedPreview = false

    private let availableVoices = ["af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore", "af_nicole", "af_nova", "af_river", "af_sarah", "af_sky", "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam", "am_michael", "am_onyx", "am_puck", "am_santa", "bf_alice", "bf_emma", "bf_isabella", "bf_lily", "bm_daniel", "bm_fable", "bm_george", "bm_lewis", "ef_dora", "em_alex", "em_santa", "ff_siwis", "hf_alpha", "hf_beta", "hm_omega", "hm_psi", "if_sara", "im_nicola", "jf_alpha", "jf_gongitsune", "jf_nezumi", "jf_tebukuro", "jm_kumo", "pf_dora", "pm_alex", "pm_santa", "zf_xiaobei", "zf_xiaoni", "zf_xiaoxiao", "zf_xiaoyi", "zm_yunjian", "zm_yunxi", "zm_yunxia", "zm_yunyang"]

    private var isBusy: Bool {
        isStreaming || isGeneratingFile || isGeneratingTrackPlacement
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            backend.isServerReady ? AnyView(speechWorkspaceView) : AnyView(startupView)
        }
        .animation(.easeInOut(duration: 0.2), value: backend.isServerReady)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 520, idealHeight: 600)
        .onAppear(perform: loadSavedRecordings)
        .onDisappear {
            cancelStreaming()
            fileTask?.cancel()
            filePlayer?.stop()
            previewPlayer?.stop()
        }
        .onChange(of: textInput) { _, _ in clearPendingNarration() }
        .onChange(of: selectedVoice) { _, _ in clearPendingNarration() }
    }

    private var startupView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Speech Studio")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
            Text(backend.initializationMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var speechWorkspaceView: some View {
        composerView
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var composerView: some View {
        VStack(alignment: .leading, spacing: 18) {
            headerView

            TextEditor(text: $textInput)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator.opacity(0.8))
                }
                .frame(minHeight: 220)
                .disabled(isBusy)

            controlsView

            Spacer()

            footerView
        }
        .padding(24)
    }

    private var headerView: some View {
        Text("Add Narration")
            .font(.system(size: 30, weight: .semibold, design: .rounded))
    }

    private var controlsView: some View {
        VStack(spacing: 14) {
            voiceSelector

            HStack(spacing: 10) {
                Button(action: startGenerateAction) {
                    if isGeneratingFile || isGeneratingTrackPlacement {
                        Label("Generating", systemImage: "hourglass")
                    } else {
                        Label("Generate", systemImage: "waveform")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy || textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()
            }

            if let pendingNarration {
                generatedPreviewView(for: pendingNarration)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func generatedPreviewView(for narration: ProjectNarration) -> some View {
        HStack(spacing: 12) {
            Button(action: { toggleGeneratedPreview(for: narration) }) {
                Image(systemName: isPlayingGeneratedPreview ? "stop.fill" : "play.fill")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .help(isPlayingGeneratedPreview ? "Stop preview" : "Play preview")

            WaveformPreview(seed: narration.url.lastPathComponent, isActive: isPlayingGeneratedPreview)
                .frame(height: 54)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator.opacity(0.65))
        }
    }

    private var footerView: some View {
        HStack(spacing: 10) {
            statusView

            Spacer()

            Button("Cancel", action: cancelAndDismiss)
                .keyboardShortcut(.cancelAction)

            Button("Insert", action: insertPendingNarration)
                .buttonStyle(.borderedProminent)
                .disabled(pendingNarration == nil || isBusy)
        }
        .padding(.top, 8)
    }

    private var voiceSelector: some View {
        Button(action: { isShowingVoicePicker.toggle() }) {
            HStack(spacing: 10) {
                Text(voiceFlag(for: selectedVoice))
                    .font(.title3)
                Text(voiceDisplayName(for: selectedVoice))
                    .font(.callout.weight(.medium))
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .disabled(isBusy)
        .popover(isPresented: $isShowingVoicePicker, arrowEdge: .bottom) {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(availableVoices, id: \.self) { voice in
                        voicePickerRow(voice)
                    }
                }
                .padding(8)
            }
            .frame(width: 360, height: 360)
        }
    }

    private func voicePickerRow(_ voice: String) -> some View {
        HStack(spacing: 10) {
            Button(action: {
                selectedVoice = voice
                isShowingVoicePicker = false
            }) {
                HStack(spacing: 10) {
                    Text(voiceFlag(for: voice))
                        .font(.title3)
                    Text(voiceDisplayName(for: voice))
                        .font(.callout)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: { playVoicePreview(for: voice) }) {
                Image(systemName: previewingVoice == voice ? "stop.fill" : "play.fill")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help("Play preview")

            if selectedVoice == voice {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            } else {
                Color.clear.frame(width: 12, height: 12)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 36)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedVoice = voice
            isShowingVoicePicker = false
        }
    }

    private func voiceDisplayName(for voice: String) -> String {
        let name = voice.split(separator: "_", maxSplits: 1).last.map(String.init) ?? voice
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    private func voiceFlag(for voice: String) -> String {
        switch String(voice.prefix(2)) {
        case "af", "am": "🇺🇸"
        case "bf", "bm": "🇬🇧"
        case "ef", "em": "🇪🇸"
        case "ff": "🇫🇷"
        case "hf", "hm": "🇮🇳"
        case "if", "im": "🇮🇹"
        case "jf", "jm": "🇯🇵"
        case "pf", "pm": "🇧🇷"
        case "zf", "zm": "🇨🇳"
        default: "🏳️"
        }
    }

    private func startGenerateAction() {
        startFileGeneration()
    }

    private func cancelAndDismiss() {
        cancelStreaming()
        fileTask?.cancel()
        filePlayer?.stop()
        previewPlayer?.stop()
        dismiss()
    }

    private func insertPendingNarration() {
        guard let pendingNarration else { return }
        filePlayer?.stop()
        isPlayingGeneratedPreview = false
        onPlaceRecording?(pendingNarration)
    }

    private func clearPendingNarration() {
        guard pendingNarration != nil else { return }
        filePlayer?.stop()
        filePlayer = nil
        isPlayingGeneratedPreview = false
        pendingNarration = nil
    }

    private var statusView: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIconName)
                .foregroundColor(statusColor)
            Text(statusMessage.isEmpty ? backend.initializationMessage : statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 10)
    }

    private var statusIconName: String {
        switch statusKind {
        case .ready:
            "checkmark.circle"
        case .busy:
            "circle.dotted"
        case .error:
            "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        switch statusKind {
        case .ready:
            .green
        case .busy:
            .secondary
        case .error:
            .red
        }
    }

    private var libraryView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Saved Audio")
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Button(action: openRecordingsFolder) {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Open folder")
                Button(action: loadSavedRecordings) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }

            if savedRecordings.isEmpty {
                ContentUnavailableView(
                    "No Saved Files",
                    systemImage: "waveform.slash",
                    description: Text("Generated audio will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(savedRecordings) { recording in
                    recordingRow(recording)
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }
                .listStyle(.inset)
            }
        }
        .padding(20)
        .background(.regularMaterial)
    }

    private func recordingRow(_ recording: SavedRecording) -> some View {
        HStack(spacing: 10) {
            Button(action: { togglePlayback(for: recording) }) {
                Image(systemName: playingRecordingID == recording.id ? "pause.fill" : "play.fill")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: 3) {
                Text(recording.title)
                    .lineLimit(1)
                    .font(.callout.weight(.medium))
                Text(recordingSubtitle(recording))
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(role: .destructive, action: { deleteRecording(recording) }) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete")
        }
    }
    private func startStreaming() {
        streamTask?.cancel()
        streamTask = Task {
            await generateStreamingSpeech()
        }
    }

    private func cancelStreaming() {
        streamTask?.cancel()
        streamTask = nil
        streamPlayer?.stop()

        if isStreaming {
            statusMessage = "Streaming canceled"
            statusKind = .ready
        }

        isStreaming = false
    }

    private func startFileGeneration() {
        fileTask?.cancel()
        fileTask = Task {
            await generateSavedSpeech(placeIntoTrack: false)
        }
    }

    private func startTrackPlacementGeneration() {
        fileTask?.cancel()
        fileTask = Task {
            await generateSavedSpeech(placeIntoTrack: true)
        }
    }

    private func generateStreamingSpeech() async {
        isStreaming = true
        statusMessage = "Opening stream handshake..."
        statusKind = .busy
        streamPlayer?.stop()
        let player = PCMStreamPlayer()
        streamPlayer = player

        defer {
            if streamTask?.isCancelled == false {
                streamTask = nil
            }
            isStreaming = false
        }

        guard let url = URL(string: "http://localhost:8000/tts") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = makeRequestBody()

        do {
            let (stream, response) = try await URLSession.shared.bytes(for: request)

            if Task.isCancelled {
                player.stop()
                statusMessage = "Streaming canceled"
                statusKind = .ready
                return
            }

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                statusMessage = "Server error: \(httpResponse.statusCode)"
                statusKind = .error
                return
            }

            try player.start()
            statusMessage = "Generating first sound..."

            var pendingNetworkBytes = Data()
            pendingNetworkBytes.reserveCapacity(4096)
            var streamedPCM = Data()
            var hasReceivedAudio = false

            for try await byte in stream {
                if Task.isCancelled {
                    player.stop()
                    statusMessage = "Streaming canceled"
                    statusKind = .ready
                    return
                }

                pendingNetworkBytes.append(byte)
                streamedPCM.append(byte)

                if pendingNetworkBytes.count >= 4096 {
                    if !hasReceivedAudio {
                        hasReceivedAudio = true
                        statusMessage = "Buffering playback..."
                    }
                    try player.append(pendingNetworkBytes)
                    pendingNetworkBytes.removeAll(keepingCapacity: true)
                    statusMessage = "Streaming sound..."
                }
            }

            if !pendingNetworkBytes.isEmpty {
                try player.append(pendingNetworkBytes, flush: true)
            }
            try player.finish()
            if !streamedPCM.isEmpty {
                let fileURL = try savePCMAsM4A(streamedPCM)
                loadSavedRecordings()
                statusMessage = "Streaming complete and saved \(fileURL.lastPathComponent)"
            } else {
                statusMessage = "Streaming complete"
            }
            statusKind = .ready
        } catch is CancellationError {
            player.stop()
            statusMessage = "Streaming canceled"
            statusKind = .ready
        } catch {
            player.stop()
            statusMessage = "Network stream broken: \(error.localizedDescription)"
            statusKind = .error
        }
    }

    private func generateSavedSpeech(placeIntoTrack: Bool) async {
        if placeIntoTrack {
            isGeneratingTrackPlacement = true
            statusMessage = "Generating narration preview..."
        } else {
            isGeneratingFile = true
            statusMessage = "Generating narration preview..."
        }
        statusKind = .busy
        let transcript = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = selectedVoice
        filePlayer?.stop()
        isPlayingGeneratedPreview = false
        pendingNarration = nil

        defer {
            fileTask = nil
            isGeneratingFile = false
            isGeneratingTrackPlacement = false
        }

        guard let url = URL(string: "http://localhost:8000/tts-file") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = makeRequestBody()

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                statusMessage = "Server error: \(httpResponse.statusCode). The /tts-file endpoint is required for saved narration."
                statusKind = .error
                return
            }

            let fileURL = try saveGeneratedAudio(data)
            loadSavedRecordings()
            pendingNarration = makeProjectNarration(fileURL, transcript: transcript, voice: voice)
            statusMessage = "Preview ready"
            statusKind = .ready
        } catch is CancellationError {
            statusMessage = "File generation canceled"
            statusKind = .ready
        } catch {
            statusMessage = "Could not save audio: \(error.localizedDescription)"
            statusKind = .error
        }
    }

    private func makeProjectNarration(_ fileURL: URL, transcript: String, voice: String) -> ProjectNarration {
        let duration = audioDuration(for: fileURL) ?? 0
        return ProjectNarration(
            url: fileURL,
            transcript: transcript,
            voice: voice,
            duration: duration
        )
    }

    private func makeRequestBody() -> Data? {
        let body: [String: Any] = [
            "text": textInput,
            "voice": selectedVoice
        ]

        return try? JSONSerialization.data(withJSONObject: body)
    }

    private func recordingsDirectory() throws -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = root.appendingPathComponent("speechapp/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func saveGeneratedAudio(_ data: Data) throws -> URL {
        let temporaryWAV = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try data.write(to: temporaryWAV, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporaryWAV) }

        let inputFile = try AVAudioFile(forReading: temporaryWAV)
        let outputURL = try makeRecordingURL(fileExtension: "m4a")
        try transcodeAudioFile(inputFile, to: outputURL)
        return outputURL
    }

    private func savePCMAsM4A(_ pcmData: Data) throws -> URL {
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let frameCount = pcmData.count / MemoryLayout<Int16>.size
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        pcmData.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            let output = buffer.floatChannelData![0]

            for index in 0..<frameCount {
                output[index] = Float(samples[index]) / Float(Int16.max)
            }
        }

        let outputURL = try makeRecordingURL(fileExtension: "m4a")
        let outputFile = try AVAudioFile(forWriting: outputURL, settings: m4aSettings)
        try outputFile.write(from: buffer)
        return outputURL
    }

    private func makeRecordingURL(fileExtension: String) throws -> URL {
        let directory = try recordingsDirectory()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"

        let prefix = sanitizedTitlePrefix()
        let filename = "\(formatter.string(from: Date()))_\(selectedVoice)_\(prefix).\(fileExtension)"
        return directory.appendingPathComponent(filename)
    }

    private var m4aSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 24_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ]
    }

    private func transcodeAudioFile(_ inputFile: AVAudioFile, to outputURL: URL) throws {
        let processingFormat = inputFile.processingFormat
        let outputFile = try AVAudioFile(forWriting: outputURL, settings: m4aSettings)
        let capacity = AVAudioFrameCount(min(inputFile.length, 16_384))

        guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: capacity) else {
            throw CocoaError(.fileWriteUnknown)
        }

        while inputFile.framePosition < inputFile.length {
            try inputFile.read(into: buffer)
            if buffer.frameLength == 0 {
                break
            }
            try outputFile.write(from: buffer)
            buffer.frameLength = 0
        }
    }

    private func audioDuration(for url: URL) -> Double? {
        guard let audioFile = try? AVAudioFile(forReading: url) else { return nil }
        let sampleRate = audioFile.fileFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        return Double(audioFile.length) / sampleRate
    }

    private func sanitizedTitlePrefix() -> String {
        let words = textInput
            .split(separator: " ")
            .prefix(5)
            .joined(separator: "-")
            .lowercased()

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = words.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let title = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return title.isEmpty ? "speech" : title
    }

    private func loadSavedRecordings() {
        do {
            let directory = try recordingsDirectory()
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )

            savedRecordings = urls
                .filter { ["m4a", "wav"].contains($0.pathExtension.lowercased()) }
                .compactMap { url in
                    let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
                    return SavedRecording(
                        url: url,
                        createdAt: values?.creationDate ?? .distantPast,
                        byteCount: Int64(values?.fileSize ?? 0)
                    )
                }
                .sorted { $0.createdAt > $1.createdAt }
        } catch {
            savedRecordings = []
            statusMessage = "Could not load saved audio: \(error.localizedDescription)"
            statusKind = .error
        }
    }

    private func openRecordingsFolder() {
        do {
            let directory = try recordingsDirectory()
            NSWorkspace.shared.open(directory)
        } catch {
            statusMessage = "Could not open folder: \(error.localizedDescription)"
            statusKind = .error
        }
    }

    private func togglePlayback(for recording: SavedRecording) {
        if playingRecordingID == recording.id {
            if filePlayer?.isPlaying == true {
                filePlayer?.pause()
            } else {
                filePlayer?.play()
            }
            return
        }

        do {
            filePlayer?.stop()
            let player = try AVAudioPlayer(contentsOf: recording.url)
            let observer = AudioPlaybackObserver()
            observer.onFinish = {
                playingRecordingID = nil
                filePlayer = nil
                playbackObserver = nil
            }
            player.delegate = observer
            player.prepareToPlay()
            player.play()
            filePlayer = player
            playbackObserver = observer
            playingRecordingID = recording.id
            statusMessage = "Playing \(recording.url.lastPathComponent)"
            statusKind = .ready
        } catch {
            statusMessage = "Could not play file: \(error.localizedDescription)"
            statusKind = .error
        }
    }

    private func toggleGeneratedPreview(for narration: ProjectNarration) {
        if isPlayingGeneratedPreview {
            filePlayer?.stop()
            filePlayer = nil
            isPlayingGeneratedPreview = false
            statusMessage = ""
            statusKind = .ready
            return
        }

        do {
            previewPlayer?.stop()
            filePlayer?.stop()
            let player = try AVAudioPlayer(contentsOf: narration.url)
            let observer = AudioPlaybackObserver()
            observer.onFinish = {
                isPlayingGeneratedPreview = false
                filePlayer = nil
                playbackObserver = nil
                statusMessage = ""
                statusKind = .ready
            }
            player.delegate = observer
            player.prepareToPlay()
            player.play()
            filePlayer = player
            playbackObserver = observer
            isPlayingGeneratedPreview = true
            statusMessage = "Playing generated preview"
            statusKind = .ready
        } catch {
            statusMessage = "Could not play generated preview: \(error.localizedDescription)"
            statusKind = .error
        }
    }

    private func playVoicePreview(for voice: String) {
        if previewingVoice == voice, previewPlayer?.isPlaying == true {
            previewPlayer?.stop()
            previewPlayer = nil
            previewingVoice = nil
            return
        }

        let previewURL = Bundle.module.url(
            forResource: voice,
            withExtension: "m4a",
            subdirectory: "speech_previews"
        ) ?? Bundle.module.url(
            forResource: "generic-fallback",
            withExtension: "m4a",
            subdirectory: "speech_previews"
        )

        guard let previewURL else {
            statusMessage = "Could not find voice preview audio"
            statusKind = .error
            return
        }

        do {
            previewPlayer?.stop()
            let player = try AVAudioPlayer(contentsOf: previewURL)
            let observer = AudioPlaybackObserver()
            observer.onFinish = {
                previewingVoice = nil
                previewPlayer = nil
                playbackObserver = nil
            }
            player.delegate = observer
            player.prepareToPlay()
            player.play()
            previewPlayer = player
            playbackObserver = observer
            previewingVoice = voice
            statusMessage = "Playing \(voiceDisplayName(for: voice)) preview"
            statusKind = .ready
        } catch {
            statusMessage = "Could not play preview: \(error.localizedDescription)"
            statusKind = .error
        }
    }

    private func deleteRecording(_ recording: SavedRecording) {
        do {
            if playingRecordingID == recording.id {
                filePlayer?.stop()
                filePlayer = nil
                playingRecordingID = nil
            }

            try FileManager.default.removeItem(at: recording.url)
            loadSavedRecordings()
            statusMessage = "Deleted \(recording.url.lastPathComponent)"
            statusKind = .ready
        } catch {
            statusMessage = "Could not delete file: \(error.localizedDescription)"
            statusKind = .error
        }
    }

    private func recordingSubtitle(_ recording: SavedRecording) -> String {
        let date = recording.createdAt.formatted(date: .abbreviated, time: .shortened)
        let size = ByteCountFormatter.string(fromByteCount: recording.byteCount, countStyle: .file)
        return "\(date) - \(size)"
    }
}
