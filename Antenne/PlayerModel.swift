import AntenneCore
import AVFoundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

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
    /// Position de reprise, appliquée dès que le flux est prêt.
    @ObservationIgnored private var startPosition: Double?
    @ObservationIgnored private var timeControlObservation: NSKeyValueObservation?
    @ObservationIgnored private let screenAwake = ScreenAwake()

    init() {
        timeControlObservation = player.observe(\.timeControlStatus) { [weak self] _, _ in
            Task { @MainActor in self?.updateScreenAwake() }
        }
    }

    func play(_ channel: Channel, from position: Double? = nil) {
        stop()
        self.channel = channel
        startPosition = position
        if StreamURL.needsVLC(channel.url) {
            playWithVLC()
        } else {
            candidates = StreamURL.candidates(for: channel.url)
            playNextCandidate()
        }
    }

    /// Position et durée en secondes ; nil pour le direct ou tant que la durée est inconnue.
    var playbackTime: (position: Double, duration: Double)? {
        switch engine {
        case .apple:
            guard let item = player.currentItem else { return nil }
            let position = player.currentTime().seconds
            let duration = item.duration.seconds
            guard position.isFinite, duration.isFinite, duration > 0 else { return nil }
            return (position, duration)
        case .vlc:
            guard let vlc, vlc.duration > 0 else { return nil }
            return (Double(vlc.elapsed) / 1000, Double(vlc.duration) / 1000)
        }
    }

    func restart() {
        switch engine {
        case .apple: player.seek(to: .zero)
        case .vlc: vlc?.seek(to: 0)
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
        updateScreenAwake()
    }

    /// L'écran reste allumé tant qu'une vidéo joue ou se charge ; en pause, la veille normale reprend.
    private func updateScreenAwake() {
        switch engine {
        case .apple:
            screenAwake.isOn = player.timeControlStatus != .paused
        case .vlc:
            screenAwake.isOn = vlc.map { $0.status == .opening || $0.status == .playing } ?? false
        }
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
        case .readyToPlay:
            if let startPosition {
                player.seek(to: CMTime(seconds: startPosition, preferredTimescale: 600))
                self.startPosition = nil
            }
            state = .playing
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
            updateScreenAwake()
            switch status {
            case .opening: state = .loading
            case .playing, .paused, .ended: state = .playing
            case .failed: state = .failed("VLC n'a pas pu lire ce flux non plus.")
            }
        }
        vlc.play(channel.url, userAgent: channel.userAgent, from: startPosition)
        startPosition = nil
        updateScreenAwake()
    }
}

/// Empêche l'écran de s'assombrir, de s'éteindre ou l'économiseur de démarrer.
/// Le lecteur d'Apple le fait seul pendant une vidéo, VLC jamais : on le demande pour les deux.
@MainActor
private final class ScreenAwake {
    var isOn = false {
        didSet {
            guard isOn != oldValue else { return }
            #if canImport(UIKit)
            UIApplication.shared.isIdleTimerDisabled = isOn
            #else
            if isOn {
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Lecture d'une vidéo")
            } else if let activity {
                ProcessInfo.processInfo.endActivity(activity)
                self.activity = nil
            }
            #endif
        }
    }

    #if !canImport(UIKit)
    private var activity: NSObjectProtocol?
    #endif
}
