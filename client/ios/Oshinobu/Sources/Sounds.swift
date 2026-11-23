import AVFoundation

/// Звук входящего сообщения в открытом приложении — тот же файл, что у Android (res/raw/msg_sound.mp3).
/// Звучит поверх текущего звука и не включается в беззвучном режиме (категория ambient).
enum MessageSound {
    nonisolated(unsafe) private static var player: AVAudioPlayer? = {
        guard let url = Bundle.main.url(forResource: "msg_sound", withExtension: "mp3") else { return nil }
        let p = try? AVAudioPlayer(contentsOf: url)
        p?.prepareToPlay()
        return p
    }()

    static func play() {
        DispatchQueue.main.async {
            // во время звонка или записи категорию не трогаем — её держат они
            let session = AVAudioSession.sharedInstance()
            if session.category != .playAndRecord { try? session.setCategory(.ambient, options: [.mixWithOthers]) }
            player?.currentTime = 0
            player?.play()
        }
    }
}
