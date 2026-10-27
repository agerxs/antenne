import AntenneCore
import SwiftUI
#if os(iOS)
import AVFoundation
#endif

@main
struct AntenneApp: App {
    @State private var store = PlaylistStore()

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
        }
        #if os(macOS)
        .defaultSize(width: 1240, height: 780)
        #endif
    }
}
