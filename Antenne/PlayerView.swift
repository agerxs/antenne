import AntenneCore
import AVKit
import SwiftUI

struct PlayerView: View {
    @Environment(PlaylistStore.self) private var store
    let channel: Channel
    @State private var model = PlayerModel()

    var body: some View {
        video
            .background(.black)
            .overlay { statusOverlay }
            .navigationTitle(channel.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem {
                    let isFavorite = store.isFavorite(channel)
                    Button { store.toggleFavorite(channel) } label: {
                        Label(isFavorite ? "Retirer des favoris" : "Ajouter aux favoris",
                              systemImage: isFavorite ? "star.fill" : "star")
                    }
                }
            }
            .task(id: channel.id) { model.play(channel) }
            .onDisappear { model.stop() }
    }

    @ViewBuilder
    private var video: some View {
        if model.engine == .vlc, let vlc = model.vlc {
            VLCPlayerView(playback: vlc)
        } else {
            PlatformPlayerView(player: model.player)
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch model.state {
        case .loading:
            ProgressView()
                .controlSize(.large)
                .tint(.white)
        case .failed(let detail):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(.secondary)
                Text("Lecture impossible")
                    .font(.headline)
                Text("Le flux ne répond pas, ou ni le lecteur d'Apple ni VLC ne savent le lire.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                Button("Réessayer") { model.play(channel) }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: 380)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding()
        case .idle, .playing:
            EmptyView()
        }
    }
}

#if os(iOS)
private struct PlatformPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}
#else
private struct PlatformPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.allowsPictureInPicturePlayback = true
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
#endif
