import AntenneCore
import SwiftUI
#if os(iOS)
import AVFoundation
#endif

@main
struct AntenneApp: App {
    /// Playlists, favoris et positions de lecture suivent l'utilisateur via iCloud.
    @State private var store = PlaylistStore(cloud: NSUbiquitousKeyValueStore.default)
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if os(iOS)
        // Son même en mode silencieux, lecture en arrière-plan et Picture in Picture.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .onReceive(NotificationCenter.default.publisher(
                    for: NSUbiquitousKeyValueStore.didChangeExternallyNotification
                )) { _ in
                    store.pullFromCloud()
                }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // Au retour dans l'app, on récupère ce qui a changé sur les autres appareils.
            guard phase == .active else { return }
            _ = NSUbiquitousKeyValueStore.default.synchronize()
            store.pullFromCloud()
        }
        #if os(macOS)
        .defaultSize(width: 1240, height: 780)
        #endif
    }
}
