import AntenneCore
import AVFoundation
import Observation

@MainActor
@Observable
final class PlayerModel {
    enum State: Equatable {
        case idle
        case loading
        case playing
        case failed(String?)
    }

    let player = AVPlayer()
    private(set) var state: State = .idle

    @ObservationIgnored private var candidates: [URL] = []
    @ObservationIgnored private var userAgent: String?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?

    func play(_ channel: Channel) {
        candidates = StreamURL.candidates(for: channel.url)
        userAgent = channel.userAgent
        playNextCandidate(lastError: nil)
    }

    func stop() {
        statusObservation = nil
        candidates = []
        player.pause()
        player.replaceCurrentItem(with: nil)
        state = .idle
    }

    private func playNextCandidate(lastError: Error?) {
        guard !candidates.isEmpty else {
            statusObservation = nil
            player.replaceCurrentItem(with: nil)
            state = .failed(lastError?.localizedDescription)
            return
        }

        let url = candidates.removeFirst()
        var options: [String: Any] = [:]
        if let userAgent { options[AVURLAssetHTTPUserAgentKey] = userAgent }
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: options))

        state = .loading
        statusObservation = item.observe(\.status) { [weak self] _, _ in
            Task { @MainActor in self?.currentItemStatusChanged() }
        }
        player.replaceCurrentItem(with: item)
        player.play()
    }

    private func currentItemStatusChanged() {
        guard let item = player.currentItem else { return }
        switch item.status {
        case .readyToPlay: state = .playing
        case .failed: playNextCandidate(lastError: item.error)
        default: break
        }
    }
}
