import AVFoundation

/// 無音の音声をループで流して、アプリが裏で眠らないようにする。
/// ほかのアプリの音楽は止めない（mixWithOthers）。
/// 電話・出力先の切り替え・音声の仕組みのリセットで止まることがあるので、知らせを受けたときと、
/// AppModel の 5 秒ごとの見回り（ensureRunning）で、鳴っていなければ流し直す
@MainActor
final class KeepAlive {
    /// 止まった・流し直したなどを、記録に残すために知らせる
    var onEvent: (@MainActor (String) -> Void)?

    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var attached = false
    /// 設定でオンにしているか。実際に鳴っているかは isPlaying
    private var wanted = false
    private var started = false
    private var lastFailure: String?
    private var observers: [NSObjectProtocol] = []
    private let format = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)!
    private lazy var buffer: AVAudioPCMBuffer = {
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22050)!
        b.frameLength = b.frameCapacity
        if let data = b.floatChannelData {
            data[0].update(repeating: 0, count: Int(b.frameLength))
        }
        return b
    }()

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
            MainActor.assumeIsolated {
                guard let self, self.wanted else { return }
                // 終わりの知らせは来ないこともあるので、来なければ見回りで流し直す
                if began { self.onEvent?("常駐用の音声が割り込みで止まった") } else { self.ensureRunning() }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.wanted else { return }
                self.onEvent?("音声の仕組みがリセットされた")
                self.rebuild()
                self.ensureRunning()
            }
        })
        // 出力先が変わる（イヤホンをつなぐなど）と、AVAudioEngine は自分で止まる
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            let changed = (note.object as AnyObject?).map { ObjectIdentifier($0) }
            MainActor.assumeIsolated {
                guard let self, self.wanted, changed == ObjectIdentifier(self.engine) else { return }
                self.onEvent?("音声の出力先が変わった")
                self.ensureRunning()
            }
        })
    }

    var isPlaying: Bool { engine.isRunning && player.isPlaying }

    func start() {
        wanted = true
        ensureRunning()
    }

    /// 鳴っていなければ流し直す
    func ensureRunning() {
        guard wanted, !isPlaying else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            if !attached {
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                attached = true
            }
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
            player.stop()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            if started { onEvent?("常駐用の音声を流し直した") }
            started = true
            lastFailure = nil
        } catch {
            // 見回りのたびに同じ失敗を記録しないように、変わったときだけ知らせる
            let message = error.localizedDescription
            if message != lastFailure { onEvent?("常駐用の音声を流せなかった（\(message)）") }
            lastFailure = message
        }
    }

    func stop() {
        wanted = false
        guard started else { return }
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        started = false
    }

    /// 音声の仕組みがリセットされたら、エンジンを作り直す
    private func rebuild() {
        engine.stop()
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        attached = false
    }
}
