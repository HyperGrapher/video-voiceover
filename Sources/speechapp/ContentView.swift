import SwiftUI
import AVFAudio
import AppKit

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

struct ContentView: View {
    @EnvironmentObject var backend: BackendProcessManager

    @State private var textInput = "Hello! I am now streaming audio dynamically chunk by chunk."
    @State private var statusMessage = ""
    @State private var statusKind: OperationStatus = .ready
    @State private var selectedVoice = "af_heart"
    @State private var streamTask: Task<Void, Never>?
    @State private var fileTask: Task<Void, Never>?
    @State private var isStreaming = false
    @State private var isGeneratingFile = false
    @State private var streamPlayer: PCMStreamPlayer?
    @State private var savedRecordings: [SavedRecording] = []
    @State private var filePlayer: AVAudioPlayer?
    @State private var playbackObserver: AudioPlaybackObserver?
    @State private var playingRecordingID: URL?

    private let availableVoices = ["af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore", "af_nicole", "af_nova", "af_river", "af_sarah", "af_sky", "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam", "am_michael", "am_onyx", "am_puck", "am_santa", "bf_alice", "bf_emma", "bf_isabella", "bf_lily", "bm_daniel", "bm_fable", "bm_george", "bm_lewis", "ef_dora", "em_alex", "em_santa", "ff_siwis", "hf_alpha", "hf_beta", "hm_omega", "hm_psi", "if_sara", "im_nicola", "jf_alpha", "jf_gongitsune", "jf_nezumi", "jf_tebukuro", "jm_kumo", "pf_dora", "pm_alex", "pm_santa", "zf_xiaobei", "zf_xiaoni", "zf_xiaoxiao", "zf_xiaoyi", "zm_yunjian", "zm_yunxi", "zm_yunxia", "zm_yunyang"]

    private var isBusy: Bool {
        isStreaming || isGeneratingFile
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            if !backend.isServerReady {
                startupView
            } else {
                appView
            }
        }
        .animation(.easeInOut(duration: 0.2), value: backend.isServerReady)
        .frame(minWidth: 860, idealWidth: 980, minHeight: 560, idealHeight: 640)
        .onAppear(perform: loadSavedRecordings)
        .onDisappear {
            cancelStreaming()
            fileTask?.cancel()
            filePlayer?.stop()
        }
    }

    private var startupView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Kokoro")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
            Text(backend.initializationMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var appView: some View {
        HStack(spacing: 0) {
            composerView
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            libraryView
                .frame(width: 320)
                .frame(maxHeight: .infinity)
        }
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

            statusView
        }
        .padding(24)
    }

    private var headerView: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Kokoro")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("Offline speech generation")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("Voice", selection: $selectedVoice) {
                ForEach(availableVoices, id: \.self) { voice in
                    Text(voice).tag(voice)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 180)
            .disabled(isBusy)
        }
    }

    private var controlsView: some View {
        HStack(spacing: 10) {
            if isStreaming {
                Button(role: .destructive, action: cancelStreaming) {
                    Label("Cancel Stream", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(action: startStreaming) {
                    Label("Stream Sound", systemImage: "waveform")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isGeneratingFile || textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Button(action: startFileGeneration) {
                if isGeneratingFile {
                    Label("Generating", systemImage: "hourglass")
                } else {
                    Label("Generate File", systemImage: "square.and.arrow.down")
                }
            }
            .disabled(isBusy || textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Spacer()

            Text("\(textInput.count) chars")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusView: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIconName)
                .foregroundColor(statusColor)
            Text(statusMessage.isEmpty ? backend.initializationMessage : statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
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
            await generateSavedSpeech()
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

    private func generateSavedSpeech() async {
        isGeneratingFile = true
        statusMessage = "Generating full audio file..."
        statusKind = .busy

        defer {
            fileTask = nil
            isGeneratingFile = false
        }

        guard let url = URL(string: "http://localhost:8000/tts-file") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = makeRequestBody()

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                if httpResponse.statusCode == 404 {
                    try await generateSavedSpeechFromStreamFallback()
                } else {
                    statusMessage = "Server error: \(httpResponse.statusCode)"
                    statusKind = .error
                }
                return
            }

            let fileURL = try saveGeneratedAudio(data)
            loadSavedRecordings()
            statusMessage = "Saved \(fileURL.lastPathComponent)"
            statusKind = .ready
        } catch is CancellationError {
            statusMessage = "File generation canceled"
            statusKind = .ready
        } catch {
            statusMessage = "Could not save audio: \(error.localizedDescription)"
            statusKind = .error
        }
    }

    private func generateSavedSpeechFromStreamFallback() async throws {
        statusMessage = "Bundled backend needs packaging for /tts-file; saving through stream..."

        guard let url = URL(string: "http://localhost:8000/tts") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = makeRequestBody()

        let (stream, response) = try await URLSession.shared.bytes(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            statusMessage = "Server error: \(httpResponse.statusCode)"
            statusKind = .error
            return
        }

        var pcmData = Data()
        for try await byte in stream {
            if Task.isCancelled {
                statusMessage = "File generation canceled"
                statusKind = .ready
                return
            }
            pcmData.append(byte)
        }

        guard !pcmData.isEmpty else {
            statusMessage = "No audio was generated"
            statusKind = .error
            return
        }

        let fileURL = try savePCMAsM4A(pcmData)
        loadSavedRecordings()
        statusMessage = "Saved \(fileURL.lastPathComponent)"
        statusKind = .ready
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
