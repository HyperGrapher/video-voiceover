import SwiftUI
import AVFAudio

struct ContentView: View {
    // Inherit the global state from your Environment
    @EnvironmentObject var backend: BackendProcessManager
    
    @State private var textInput: String = "Hello! I am now streaming audio dynamically chunk by chunk."
    @State private var statusMessage: String = ""
    @State private var isProcessing: Bool = false
    
    @State private var accumulatedData = Data()
    @State private var audioPlayer: AVAudioPlayer?
    @State private var hasStartedPlayback = false
    
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
                                Text("Stream Text")
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
        accumulatedData = Data()
        hasStartedPlayback = false
        
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
            
            statusMessage = "Receiving stream packets..."
            
            for try await byte in stream {
                accumulatedData.append(byte)
                
                if accumulatedData.count >= 48000 && !hasStartedPlayback {
                    hasStartedPlayback = true
                    statusMessage = "Streaming playback active..."
                    playCurrentBuffer()
                }
            }
            
            if !hasStartedPlayback {
                playCurrentBuffer()
            }
            
            statusMessage = "Streaming complete!"
        } catch {
            statusMessage = "❌ Network stream broken: \(error.localizedDescription)"
        }
        isProcessing = false
    }
    
    private func playCurrentBuffer() {
        let snapshotData = accumulatedData
        DispatchQueue.main.async {
            do {
                self.audioPlayer = try AVAudioPlayer(data: snapshotData)
                self.audioPlayer?.prepareToPlay()
                self.audioPlayer?.play()
            } catch {
                print("Buffer decoding lag: \(error)")
            }
        }
    }
}
