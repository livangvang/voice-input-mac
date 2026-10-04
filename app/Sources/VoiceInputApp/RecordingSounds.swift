import AVFoundation
import Foundation

@MainActor
final class RecordingSounds {
    enum Cue: String, CaseIterable { case start, finish }
    private var players: [Cue: AVAudioPlayer] = [:]

    init() {
        for cue in Cue.allCases {
            guard let url = Bundle.main.url(forResource: cue.rawValue, withExtension: "wav", subdirectory: "Sounds"),
                  let player = try? AVAudioPlayer(contentsOf: url) else {
                VoiceDiagnostics.record(.cueUnavailable)
                continue
            }
            player.volume = 1
            player.prepareToPlay()
            players[cue] = player
        }
    }

    func play(_ cue: Cue) {
        // A quick start/finish should still produce distinct cues without overlapping.
        for player in players.values { player.pause(); player.currentTime = 0 }
        guard let player = players[cue], player.play() else {
            VoiceDiagnostics.record(.cueUnavailable)
            return
        }
        VoiceDiagnostics.record(cue == .start ? .startCuePlayed : .finishCuePlayed)
    }
}
