import SwiftUI
import AVFAudio

struct ContentView: View {
    @State private var textInput: String = "Hello! I am generating speech on an Intel Mac using a local Python bridge."
    @State private var statusMessage: String = "Engine Ready"
    @State private var isProcessing: Bool = false
    @State private var audioPlayer: AVAudioPlayer?
    
    // Add any voices you downloaded to your local python package layout
    // let availableVoices = ["af_heart", "af_bella", "am_adam"]
    let availableVoices = [
  "af_alloy",
  "af_aoede",
  "af_bella",
  "af_heart",
  "af_jessica",
  "af_kore",
  "af_nicole",
  "af_nova",
  "af_river",
  "af_sarah",
  "af_sky",
  "am_adam",
  "am_echo",
  "am_eric",
  "am_fenrir",
  "am_liam",
  "am_michael",
  "am_onyx",
  "am_puck",
  "am_santa",
  "bf_alice",
  "bf_emma",
  "bf_isabella",
  "bf_lily",
  "bm_daniel",
  "bm_fable",
  "bm_george",
  "bm_lewis",
  "ef_dora",
  "em_alex",
  "em_santa",
  "ff_siwis",
  "hf_alpha",
  "hf_beta",
  "hm_omega",
  "hm_psi",
  "if_sara",
  "im_nicola",
  "jf_alpha",
  "jf_gongitsune",
  "jf_nezumi",
  "jf_tebukuro",
  "jm_kumo",
  "pf_dora",
  "pm_alex",
  "pm_santa",
  "zf_xiaobei",
  "zf_xiaoni",
  "zf_xiaoxiao",
  "zf_xiaoyi",
  "zm_yunjian",
  "zm_yunxi",
  "zm_yunxia",
  "zm_yunyang"
]
    @State private var selectedVoice: String = "af_heart"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Kokoro Intel Bridge Engine")
                .font(.headline)
            
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
                    Task { await generateSpeech() }
                }) {
                    if isProcessing {
                        ProgressView().controlSize(.small).padding(.horizontal, 4)
                    } else {
                        Text("Speak Text")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isProcessing || textInput.isEmpty)
                
                Spacer()
                
                Text(statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled) // Allows you to click and drag to copy the full error text
                    .frame(maxWidth: 350, alignment: .trailing)
            }
        }
        .padding()
        .frame(width: 650, height: 280)
    }

    private func generateSpeech() async {
        isProcessing = true
        statusMessage = "Sending request to Python core..."
        
        guard let url = URL(string: "http://localhost:8000/tts") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "text": textInput,
            "voice": selectedVoice
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                statusMessage = "❌ Server error code: \(httpResponse.statusCode)"
                isProcessing = false
                return
            }
            
            statusMessage = "Playing audio..."
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.play()
            statusMessage = "Success!"
        } catch {
            statusMessage = "❌ Connection failed: \(error.localizedDescription)"
        }
        isProcessing = false
    }
}
