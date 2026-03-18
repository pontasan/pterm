import AVFoundation
import Foundation

protocol TypewriterKeyClicking: AnyObject {
    func playKeystroke()
}

final class NullTypewriterKeyClickPlayer: TypewriterKeyClicking {
    static let shared = NullTypewriterKeyClickPlayer()

    private init() {}

    func playKeystroke() {}
}

enum TypewriterKeyClickPlayerFactory {
    static var defaultPlayer: TypewriterKeyClicking {
        isRunningUnitTests ? NullTypewriterKeyClickPlayer.shared : TypewriterSoundPlayer.shared
    }

    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            NSClassFromString("XCTestCase") != nil
    }
}

final class TypewriterSoundPlayer: NSObject, TypewriterKeyClicking, AVAudioPlayerDelegate {
    private final class SoundVariant {
        let players: [AVAudioPlayer]
        private var nextPlayerIndex = 0

        init(players: [AVAudioPlayer]) {
            self.players = players
        }

        func takeIdlePlayer() -> AVAudioPlayer? {
            guard !players.isEmpty else { return nil }

            for offset in 0..<players.count {
                let index = (nextPlayerIndex + offset) % players.count
                let player = players[index]
                if !player.isPlaying {
                    nextPlayerIndex = (index + 1) % players.count
                    return player
                }
            }

            return nil
        }

        func stopAll() {
            for player in players where player.isPlaying {
                player.stop()
                player.currentTime = 0
            }
        }
    }

    static let shared = TypewriterSoundPlayer()
    private static let playerPoolSizePerSound = 1

    private let soundURLs: [URL]
    private var variants: [SoundVariant] = []
    private var lastPlayedIndex: Int?
    private var isEnabled = false
    var debugSoundFileCount: Int { soundURLs.count }
    var debugLoadedPlayerCount: Int { variants.reduce(0) { $0 + $1.players.count } }

    override init() {
        self.soundURLs = Self.resolveSoundURLs()
        precondition(!soundURLs.isEmpty, "Missing bundled typewriter audio files in Resources/Audio")
        super.init()
    }

    init(soundURLs: [URL]) {
        precondition(!soundURLs.isEmpty, "Missing bundled typewriter audio files in Resources/Audio")
        self.soundURLs = soundURLs
        super.init()
    }

    func configure(enabled: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))

        isEnabled = enabled
        if !enabled {
            unload()
        }
    }

    func preloadIfNeeded() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard variants.isEmpty else { return }

        do {
            variants = try soundURLs.map { soundURL in
                let players = try (0..<Self.playerPoolSizePerSound).map { _ in
                    let player = try AVAudioPlayer(contentsOf: soundURL)
                    player.delegate = self
                    player.volume = 1.0
                    player.prepareToPlay()
                    return player
                }
                return SoundVariant(players: players)
            }
        } catch {
            variants.removeAll(keepingCapacity: false)
            assertionFailure("Failed to preload typewriter audio players: \(error)")
        }
    }

    func playKeystroke() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isEnabled else { return }
        preloadIfNeeded()
        guard !variants.isEmpty else {
            assertionFailure("Typewriter keystroke audio was requested before preload")
            return
        }

        let preferredIndex = nextSoundIndex()
        let orderedIndices = Array(preferredIndex..<variants.count) + Array(0..<preferredIndex)
        guard let player = orderedIndices.lazy.compactMap({ self.variants[$0].takeIdlePlayer() }).first else {
            return
        }

        player.currentTime = 0
        if !player.play() {
            assertionFailure("Failed to play preloaded typewriter audio")
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        player.currentTime = 0
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        player.stop()
        player.currentTime = 0
        if let error {
            assertionFailure("Typewriter audio decode error: \(error)")
        }
    }

    private func unload() {
        for variant in variants {
            variant.stopAll()
        }
        variants.removeAll(keepingCapacity: false)
        lastPlayedIndex = nil
    }

    private func nextSoundIndex() -> Int {
        var nextIndex: Int
        if variants.count == 1 {
            nextIndex = 0
        } else {
            repeat {
                nextIndex = Int.random(in: 0..<variants.count)
            } while nextIndex == lastPlayedIndex
        }
        lastPlayedIndex = nextIndex
        return nextIndex
    }

    private static func resolveSoundURLs() -> [URL] {
        let candidateDirectories = [
            Bundle.main.resourceURL?.appendingPathComponent("Audio", isDirectory: true),
            projectRootURL()
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("Audio", isDirectory: true)
        ]

        for directoryURL in candidateDirectories.compactMap({ $0 }) {
            if let urls = try? FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                let sounds = urls
                    .filter { $0.pathExtension.lowercased() == "aiff" }
                    .sorted {
                        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                    }
                if !sounds.isEmpty {
                    return sounds
                }
            }
        }

        return []
    }

    private static func projectRootURL(filePath: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(filePath)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
