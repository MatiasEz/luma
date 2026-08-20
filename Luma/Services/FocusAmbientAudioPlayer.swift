import AVFoundation
import Foundation
import Observation

enum RainAmbience: String, CaseIterable, Identifiable {
    case soft
    case window
    case forest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .soft: "Lluvia suave"
        case .window: "Lluvia en la ventana"
        case .forest: "Lluvia en el bosque"
        }
    }

    var detail: String {
        switch self {
        case .soft: "Pareja y constante"
        case .window: "Más cercana y envolvente"
        case .forest: "Natural y espaciosa"
        }
    }

    var systemImage: String {
        switch self {
        case .soft: "cloud.drizzle.fill"
        case .window: "window.casement.closed"
        case .forest: "tree.fill"
        }
    }

    fileprivate var resourceName: String {
        switch self {
        case .soft: "rain_soft"
        case .window: "rain_window"
        case .forest: "rain_forest"
        }
    }
}

@MainActor
@Observable
final class FocusAmbientAudioPlayer {
    private static let ambienceKey = "lumaFocusRainAmbience"
    private static let volumeKey = "lumaFocusRainVolume"
    private static let enabledKey = "lumaFocusRainEnabled"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var player: AVAudioPlayer?

    var selectedAmbience: RainAmbience {
        didSet {
            defaults.set(selectedAmbience.rawValue, forKey: Self.ambienceKey)
            reloadPreservingPlayback()
        }
    }

    private(set) var volume: Double
    private(set) var isPlaying = false
    private(set) var loadError: String?

    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.enabledKey)
            if !isEnabled { stop() }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedAmbience = RainAmbience(
            rawValue: defaults.string(forKey: Self.ambienceKey) ?? ""
        ) ?? .soft

        let savedVolume = defaults.object(forKey: Self.volumeKey) as? Double
        volume = min(max(savedVolume ?? 0.34, 0), 1)
        isEnabled = defaults.object(forKey: Self.enabledKey) == nil
            ? true
            : defaults.bool(forKey: Self.enabledKey)

        preparePlayer()
    }

    func setVolume(_ newValue: Double) {
        volume = min(max(newValue, 0), 1)
        player?.volume = Float(volume)
        defaults.set(volume, forKey: Self.volumeKey)
    }

    func play() {
        guard isEnabled else { return }
        if player == nil { preparePlayer() }
        guard let player else { return }
        player.volume = Float(volume)
        isPlaying = player.play()
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        isPlaying = false
    }

    func togglePreview() {
        isPlaying ? pause() : play()
    }

    private func reloadPreservingPlayback() {
        let shouldResume = isPlaying
        player?.stop()
        player = nil
        isPlaying = false
        preparePlayer()
        if shouldResume { play() }
    }

    private func preparePlayer() {
        let resource = selectedAmbience.resourceName
        let url = Bundle.main.url(forResource: resource, withExtension: "mp3")
            ?? Bundle.main.url(forResource: resource, withExtension: "mp3", subdirectory: "Audio")

        guard let url else {
            loadError = "No pude cargar este sonido."
            return
        }

        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.numberOfLoops = -1
            newPlayer.volume = Float(volume)
            newPlayer.prepareToPlay()
            player = newPlayer
            loadError = nil
        } catch {
            player = nil
            loadError = "No pude reproducir este sonido."
        }
    }
}
