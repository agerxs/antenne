import Observation
import SwiftUI
#if os(iOS)
import MobileVLCKit
#else
import VLCKit
#endif

/// Lecture par VLC, en secours du lecteur d'Apple (MKV, AVI, RTMP…).
@MainActor
@Observable
final class VLCPlayback {
    enum Status: Equatable {
        case opening, playing, paused, ended, failed
    }

    private(set) var status: Status = .opening
    /// Position de 0 à 1, durée et temps écoulé en millisecondes (durée nulle pour le direct).
    private(set) var position: Double = 0
    private(set) var elapsed = 0
    private(set) var duration = 0

    @ObservationIgnored let player = VLCMediaPlayer()
    @ObservationIgnored private var bridge: DelegateBridge?
    @ObservationIgnored var onStatusChange: ((Status) -> Void)?

    init() {
        let bridge = DelegateBridge(owner: self)
        self.bridge = bridge
        player.delegate = bridge
    }

    func play(_ url: URL, userAgent: String?) {
        let media = VLCMedia(url: url)
        media.addOption(":network-caching=1500")
        if let userAgent { media.addOption(":http-user-agent=\(userAgent)") }
        player.media = media
        update(status: .opening)
        player.play()
    }

    func togglePause() {
        if player.isPlaying { player.pause() } else { player.play() }
    }

    func seek(to fraction: Double) {
        guard player.isSeekable else { return }
        player.position = Float(min(max(fraction, 0), 1))
        position = fraction
    }

    func stop() {
        onStatusChange = nil
        player.stop()
        player.media = nil
    }

    var isSeekable: Bool { duration > 0 && player.isSeekable }

    fileprivate func stateChanged() {
        switch player.state {
        case .playing: update(status: .playing)
        case .paused: update(status: .paused)
        case .error: update(status: .failed)
        // Un flux qui s'arrête sans avoir rien joué n'a pas pu être lu.
        case .ended, .stopped: update(status: elapsed > 0 ? .ended : .failed)
        case .opening, .buffering, .esAdded: break
        @unknown default: break
        }
    }

    fileprivate func timeChanged() {
        elapsed = Int(player.time.intValue)
        duration = Int(player.media?.length.intValue ?? 0)
        position = Double(player.position)
        if status == .opening { update(status: .playing) }
    }

    private func update(status: Status) {
        guard self.status != status else { return }
        self.status = status
        onStatusChange?(status)
    }

    /// VLCMediaPlayer exige un délégué NSObject.
    private final class DelegateBridge: NSObject, VLCMediaPlayerDelegate {
        weak var owner: VLCPlayback?

        init(owner: VLCPlayback) {
            self.owner = owner
        }

        func mediaPlayerStateChanged(_ aNotification: Notification) {
            Task { @MainActor [weak owner] in owner?.stateChanged() }
        }

        func mediaPlayerTimeChanged(_ aNotification: Notification) {
            Task { @MainActor [weak owner] in owner?.timeChanged() }
        }
    }
}

// MARK: Vue

struct VLCPlayerView: View {
    let playback: VLCPlayback
    @State private var showsControls = true
    @State private var scrubbing: Double?

    var body: some View {
        VLCSurface(player: playback.player)
            .background(.black)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showsControls.toggle() } }
            .overlay(alignment: .bottom) {
                if showsControls { controls }
            }
            .task(id: showsControls) {
                // Les commandes s'effacent seules pendant la lecture.
                guard showsControls else { return }
                try? await Task.sleep(for: .seconds(4))
                if playback.status == .playing, scrubbing == nil {
                    withAnimation(.easeInOut(duration: 0.3)) { showsControls = false }
                }
            }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button { playback.togglePause() } label: {
                Image(systemName: playback.status == .paused ? "play.fill" : "pause.fill")
                    .font(.title3)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.status == .paused ? "Lecture" : "Pause")

            if playback.isSeekable {
                Text(format(playback.elapsed)).monospacedDigit()
                Slider(
                    value: Binding(get: { scrubbing ?? playback.position }, set: { scrubbing = $0 }),
                    in: 0...1
                ) { editing in
                    if !editing, let scrubbing {
                        playback.seek(to: scrubbing)
                        self.scrubbing = nil
                    }
                }
                Text(format(playback.duration)).monospacedDigit()
            } else {
                Text("Direct").font(.caption.weight(.semibold))
                Spacer()
            }

            Text("VLC")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.white.opacity(0.15), in: Capsule())
                .accessibilityLabel("Lecture via VLC")
        }
        .font(.caption)
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding()
        .transition(.opacity)
    }

    private func format(_ milliseconds: Int) -> String {
        let seconds = max(milliseconds, 0) / 1000
        let (h, m, s) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

#if os(iOS)
private struct VLCSurface: UIViewRepresentable {
    let player: VLCMediaPlayer

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        player.drawable = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {}
}
#else
private struct VLCSurface: NSViewRepresentable {
    let player: VLCMediaPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        player.drawable = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
#endif
