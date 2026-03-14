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
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

final class TypewriterSoundPlayer: NSObject, TypewriterKeyClicking, AVAudioPlayerDelegate {
    static let shared = TypewriterSoundPlayer()

    private let soundURLs: [URL]
    private var activePlayers: [ObjectIdentifier: AVAudioPlayer] = [:]
    private var lastPlayedIndex: Int?
    var debugSoundFileCount: Int { soundURLs.count }

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

    func playKeystroke() {
        dispatchPrecondition(condition: .onQueue(.main))
        pruneFinishedPlayers()

        let soundURL = nextSoundURL()

        do {
            let player = try AVAudioPlayer(contentsOf: soundURL)
            player.delegate = self
            player.volume = 1.0
            player.prepareToPlay()

            let identifier = ObjectIdentifier(player)
            activePlayers[identifier] = player

            if !player.play() {
                activePlayers.removeValue(forKey: identifier)
                assertionFailure("Failed to play typewriter audio: \(soundURL.lastPathComponent)")
            }
        } catch {
            assertionFailure("Failed to load typewriter audio at \(soundURL.path): \(error)")
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        removePlayer(player)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        removePlayer(player)
        if let error {
            assertionFailure("Typewriter audio decode error: \(error)")
        }
    }

    private func nextSoundURL() -> URL {
        var nextIndex: Int
        if soundURLs.count == 1 {
            nextIndex = 0
        } else {
            repeat {
                nextIndex = Int.random(in: 0..<soundURLs.count)
            } while nextIndex == lastPlayedIndex
        }
        lastPlayedIndex = nextIndex
        return soundURLs[nextIndex]
    }

    private func pruneFinishedPlayers() {
        activePlayers = activePlayers.filter { $0.value.isPlaying }
    }

    private func removePlayer(_ player: AVAudioPlayer) {
        let removal = {
            _ = self.activePlayers.removeValue(forKey: ObjectIdentifier(player))
        }
        if Thread.isMainThread {
            removal()
        } else {
            DispatchQueue.main.async(execute: removal)
        }
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
