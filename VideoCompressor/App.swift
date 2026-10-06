import SwiftUI

@main
struct VideoCompressorApp: App {
    init() {
        // UI tests launch with this flag so each test starts from a clean
        // slate. Without it, a batch saved by the previous test is (correctly)
        // restored, and the app opens on that batch instead of the library.
        if ProcessInfo.processInfo.arguments.contains("-resetForUITests") {
            try? FileManager.default.removeItem(at: BatchSnapshot.defaultURL)
            if let domain = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: domain)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
