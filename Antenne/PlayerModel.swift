import AntenneCore
import AVFoundation
import Observation

/// Lecteur d'Apple d'abord (Picture in Picture, AirPlay), VLC pour ce qu'il ne sait pas lire.
@MainActor
@Observable
final class PlayerModel {
    enum State: Equatable {
        case idle
        case loading
        case playing
        case failed(String?)
    }

    enum Engine {
        case apple, vlc
    }

    let player = AVPlayer()
    private(set) var state: State = .idle
    private(set) var engine: Engine = .apple
    /// Créé au premier besoin : VLC charge ses modules au démarrage.
    private(set) var vlc: VLCPlayback?

    @ObservationIgnored private var channel: Channel?
    @ObservationIgnored private var candidates: [URL] = []
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?

    func play(_ channel: Channel) {
        stop()
        self.channel = channel
        if StreamURL.needsVLC(channel.url) {
            playWithVLC()
        } else {
            candidates = StreamURL.candidates(for: channel.url)
            playNextCandidate()
        }
    }

    func stop() {
        statusObservation = nil
        candidates = []
        player.pause()
        player.replaceCurrentItem(with: nil)
        vlc?.stop()
        engine = .apple
        state = .idle
    }

    private func playNextCandidate() {
        guard !candidates.isEmpty else {
            // Le lecteur d'Apple a tout essayé : VLC prend le relais.
            statusObservation = nil
            player.replaceCurrentItem(with: nil)
            playWithVLC()
            return
        }

        let url = candidates.removeFirst()
        var options: [String: Any] = [:]
        if let userAgent = channel?.userAgent { options[AVURLAssetHTTPUserAgentKey] = userAgent }
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: options))

        engine = .apple
        state = .loading
        statusObservation = item.observe(\.status) { [weak self] _, _ in
            Task { @MainActor in self?.currentItemStatusChanged() }
        }
        player.replaceCurrentItem(with: item)
        player.play()
    }

    private func currentItemStatusChanged() {
        guard engine == .apple, let item = player.currentItem else { return }
        switch item.status {
        case .readyToPlay: state = .playing
        case .failed: playNextCandidate()
        default: break
        }
    }

    private func playWithVLC() {
        guard let channel else { return }
        let vlc = vlc ?? VLCPlayback()
        self.vlc = vlc
        engine = .vlc
        state = .loading
        vlc.onStatusChange = { [weak self] status in
            guard let self, self.engine == .vlc else { return }
            switch status {
            case .opening: state = .loading
            case .playing, .paused, .ended: state = .playing
            case .failed: state = .failed("VLC n'a pas pu lire ce flux non plus.")
            }
        }
        vlc.play(channel.url, userAgent: channel.userAgent)
    }
}
