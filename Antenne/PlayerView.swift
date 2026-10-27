import AntenneCore
import AVKit
import SwiftUI

struct PlayerView: View {
    @Environment(PlaylistStore.self) private var store
    let channel: Channel
    @State private var model = PlayerModel()
    @State private var resumedFrom: Double?

    var body: some View {
        content
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
            .task(id: channel.id) {
                let resume = store.progress(for: channel)?.resumePosition
                resumedFrom = resume
                model.play(channel, from: resume)
                // Position notée régulièrement : la reprise marche même après une fermeture brutale.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    recordProgress()
                }
            }
            .task(id: resumedFrom) {
                guard resumedFrom != nil else { return }
                // Une annulation (la vue apparaît deux fois à l'ouverture sur iPhone) ne doit pas
                // masquer le bandeau avant l'heure.
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                withAnimation { resumedFrom = nil }
            }
            .onDisappear {
                recordProgress()
                model.stop()
            }
    }

    /// Une chaîne en direct d'un compte affiche son guide sous la vidéo.
    @ViewBuilder
    private var content: some View {
        if channel.streamID != nil, let client = store.xtreamClient(for: channel) {
            VStack(spacing: 0) {
                screen.aspectRatio(16 / 9, contentMode: .fit)
                GuidePanel(channel: channel, client: client)
            }
        } else {
            screen
        }
    }

    private var screen: some View {
        video
            .background(.black)
            .overlay { statusOverlay }
            .overlay(alignment: .top) { resumeBanner }
    }

    private func recordProgress() {
        guard let time = model.playbackTime else { return }
        store.recordProgress(channel, position: time.position, duration: time.duration)
    }

    @ViewBuilder
    private var resumeBanner: some View {
        if let resumedFrom, model.state == .playing {
            HStack(spacing: 14) {
                Text("Reprise à \(timecode(resumedFrom))")
                Button("Reprendre au début") {
                    model.restart()
                    withAnimation { self.resumedFrom = nil }
                }
                .buttonStyle(.borderless)
                .fontWeight(.semibold)
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 12)
            .transition(.opacity)
        }
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
