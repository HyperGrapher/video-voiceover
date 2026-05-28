// The Swift Programming Language
// https://docs.swift.org/swift-book
import SwiftUI

@main
struct speechapp: App {
    // Read the application phase (active, background, inactive)
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var backendManager = BackendProcessManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(backendManager)
        }
        // Monitor scene changes to cleanly terminate the Python server when closing
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .background {
                // Keep running if minimized, but optional handle here
            }
        }
    }
}
