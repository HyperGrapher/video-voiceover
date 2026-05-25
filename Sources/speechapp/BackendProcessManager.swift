import Foundation
import SwiftUI

@MainActor
class BackendProcessManager: ObservableObject {
    static let shared = BackendProcessManager()
    
    @Published var isServerReady = false
    @Published var initializationMessage = "Starting system infrastructure..."
    
    private var backendProcess: Process?
    private var monitoringTask: Task<Void, Never>?
    
    private init() {
        startBackendServer()
    }
    
    func startBackendServer() {
        guard let binaryURL = Bundle.module.url(forResource: "tts_backend", withExtension: nil) else {
            self.initializationMessage = "❌ Core binary 'tts_backend' missing from Resources."
            return
        }

        let process = Process()
        process.executableURL = binaryURL
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            self.backendProcess = process
            
            // Start the modern Swift Concurrency loop instead of an legacy Timer instance
            startPingHandshakeLoop()
        } catch {
            self.initializationMessage = "❌ Subprocess initiation error: \(error.localizedDescription)"
        }
    }
    
    private func startPingHandshakeLoop() {
        guard let url = URL(string: "http://localhost:8000/docs") else { return }
        
        // Cancel any existing tasks to avoid overlapping loops
        monitoringTask?.cancel()
        
        // Spawn an async Task that natively inherits @MainActor isolation context
        monitoringTask = Task {
            var ticks = 0
            let maxTicks = 40 // 40 ticks * 0.5s = 20-second timeout tracking window
            
            while ticks < maxTicks && !self.isServerReady && !Task.isCancelled {
                ticks += 1
                
                // Sleep cleanly without blocking UI threads for 0.5 seconds
                do {
                    try await Task.sleep(nanoseconds: 500_000_000)
                } catch {
                    break // Task was cancelled, exit the loop cleanly
                }
                
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = 0.4
                
                do {
                    let (_, response) = try await URLSession.shared.data(for: request)
                    if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                        self.isServerReady = true
                        self.initializationMessage = "Engine Ready"
                        break // Success, exit out of loop tracking structures
                    }
                } catch {
                    // Swallowing exception; the background script is still loading model weights
                }
            }
            
            // Handle timeout checking if loop exited without validation mapping
            if !self.isServerReady && !Task.isCancelled {
                self.initializationMessage = "❌ Server initialization timed out."
            }
        }
    }
    
    deinit {
        // Only modify or terminate process instances from nonisolated constraints
        if let process = backendProcess, process.isRunning {
            process.terminate()
        }
    }
}
