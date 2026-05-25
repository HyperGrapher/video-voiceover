import SwiftUI
import AVFAudio

final class PCMStreamPlayer {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var pendingData = Data()
    private let minimumBufferedFrames = 4096
    private var isPrepared = false

    init(sampleRate: Double = 24_000) {
        self.format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
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

        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    func append(_ data: Data, flush: Bool = false) throws {
        pendingData.append(data)

        let bytesPerFrame = MemoryLayout<Int16>.size
        let completeFrameCount = pendingData.count / bytesPerFrame
        guard completeFrameCount > 0 else { return }

        if !flush && completeFrameCount < minimumBufferedFrames {
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

        playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }

    func finish() throws {
        try append(Data(), flush: true)
    }

    func stop() {
        playerNode.stop()
        engine.stop()
        pendingData.removeAll(keepingCapacity: true)
    }
}

struct ContentView: View {
    // Inherit the global state from your Environment
    @EnvironmentObject var backend: BackendProcessManager
    
    @State private var textInput: String = "Hello! I am now streaming audio dynamically chunk by chunk."
    @State private var statusMessage: String = ""
    @State private var isProcessing: Bool = false
    
    @State private var streamPlayer: PCMStreamPlayer?
    
    let availableVoices = ["af_heart", "af_bella", "am_adam"]
    @State private var selectedVoice: String = "af_heart"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Kokoro Realtime Streaming Engine")
                .font(.headline)
            
            if !backend.isServerReady {
                // THE LOADING UI LAYER
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text(backend.initializationMessage)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            } else {
                // THE FULL OPERATIONAL UI LAYER
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Select Voice:")
                        Picker("", selection: $selectedVoice) {
                            ForEach(availableVoices, id: \.self) { voice in
                                Text(voice).tag(voice)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 180)
                        .disabled(isProcessing)
                    }
                    
                    TextEditor(text: $textInput)
                        .font(.body)
                        .frame(height: 100)
                        .padding(4)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
                    
                    HStack {
                        Button(action: {
                            Task { await generateStreamingSpeech() }
                        }) {
                            if isProcessing {
                                ProgressView().controlSize(.small).padding(.horizontal, 4)
                            } else {
                                Text("Stream Sound")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isProcessing || textInput.isEmpty)
                        
                        Spacer()
                        
                        Text(statusMessage.isEmpty ? backend.initializationMessage : statusMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: 350, alignment: .trailing)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding()
        .animation(.easeInOut, value: backend.isServerReady)
        .frame(width: 650, height: 280)
    }

    private func generateStreamingSpeech() async {
        isProcessing = true
        statusMessage = "Opening stream handshake..."
        streamPlayer?.stop()
        let player = PCMStreamPlayer()
        streamPlayer = player
        
        guard let url = URL(string: "http://localhost:8000/tts") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = ["text": textInput, "voice": selectedVoice]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        do {
            let (stream, response) = try await URLSession.shared.bytes(for: request)
            
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                statusMessage = "❌ Server error: \(httpResponse.statusCode)"
                isProcessing = false
                return
            }
            
            try player.start()
            statusMessage = "Streaming sound..."
            
            var pendingNetworkBytes = Data()
            pendingNetworkBytes.reserveCapacity(8192)

            for try await byte in stream {
                pendingNetworkBytes.append(byte)

                if pendingNetworkBytes.count >= 8192 {
                    try player.append(pendingNetworkBytes)
                    pendingNetworkBytes.removeAll(keepingCapacity: true)
                }
            }

            if !pendingNetworkBytes.isEmpty {
                try player.append(pendingNetworkBytes, flush: true)
            }
            try player.finish()
            statusMessage = "Streaming complete!"
        } catch {
            statusMessage = "❌ Network stream broken: \(error.localizedDescription)"
            player.stop()
        }
        isProcessing = false
    }
}
