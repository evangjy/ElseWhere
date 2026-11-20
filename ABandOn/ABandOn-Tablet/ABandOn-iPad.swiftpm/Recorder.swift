import Foundation
import AVFoundation

struct RecError: LocalizedError {
    let msg: String
    var errorDescription: String? { msg }
}

/// 原生录音：从声卡/吉他输入采集 1 声道 16-bit WAV，带电平表。
/// 录音与伴奏播放同时进行；保存时由页面把文件放进资料库对应曲目文件夹。
final class Recorder {
    static let shared = Recorder()
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var mono: AVAudioFormat?
    private var frames: Int64 = 0
    private var rate: Double = 44100
    private var current: String?
    private var last: URL?
    private var tick: Int = 0

    // MARK: 设备与权限
    func devices() -> [[String: String]] {
        var out: [[String: String]] = []
        #if os(iOS)
        let inputs = AVAudioSession.sharedInstance().availableInputs ?? []
        for i in inputs { out.append(["id": i.uid, "name": i.portName]) }
        #else
        let name: String = AVCaptureDevice.default(for: .audio)?.localizedName ?? "系统默认输入"
        out.append(["id": "default", "name": name + "（在系统设置 > 声音 中切换）"])
        #endif
        return out
    }

    private func access(_ done: @escaping (Bool) -> Void) {
        #if os(iOS)
        AVAudioSession.sharedInstance().requestRecordPermission { ok in DispatchQueue.main.async { done(ok) } }
        #else
        AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
        #endif
    }

    // MARK: 引擎
    private func ensureRunning(_ deviceID: String?) throws {
        if engine.isRunning && deviceID == current { return }
        stopEngine()
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try s.setActive(true)
        if let id = deviceID, let p = s.availableInputs?.first(where: { $0.uid == id }) { try s.setPreferredInput(p) }
        #endif
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        if fmt.sampleRate == 0 || fmt.channelCount == 0 { throw RecError(msg: "没有可用的音频输入设备，请连接声卡或吉他输入") }
        rate = fmt.sampleRate
        mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fmt.sampleRate, channels: 1, interleaved: false)
        input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] buf, _ in self?.process(buf) }
        engine.prepare()
        try engine.start()
        current = deviceID
    }

    private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        current = nil
    }

    private func process(_ buf: AVAudioPCMBuffer) {
        guard let src = buf.floatChannelData?[0], let fmt = mono else { return }
        let n: Int = Int(buf.frameLength)
        var peak: Float = 0
        for i in 0..<n {
            let v: Float = abs(src[i])
            if v > peak { peak = v }
        }
        lock.lock()
        if let f = file, let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) {
            out.frameLength = AVAudioFrameCount(n)
            out.floatChannelData![0].update(from: src, count: n)
            try? f.write(from: out)
            frames += Int64(n)
        }
        lock.unlock()
        tick += 1
        if tick % 2 == 0 {
            let p = peak
            DispatchQueue.main.async { self.onLevel?(p) }
        }
    }

    private func beginFile() throws {
        let u: URL = FileManager.default.temporaryDirectory.appendingPathComponent("take-\(Int(Date().timeIntervalSince1970)).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let f = try AVAudioFile(forWriting: u, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        lock.lock(); file = f; frames = 0; lock.unlock()
        last = u
    }

    private func endFile() -> [String: Any] {
        lock.lock()
        let dur: Double = Double(frames) / rate
        file = nil
        lock.unlock()
        return ["ok": true, "dur": dur]
    }

    // MARK: 页面指令
    func handle(_ cmd: String, _ a: [String: Any], _ done: @escaping (Any) -> Void) {
        let dev: String? = a["deviceId"] as? String
        switch cmd {
        case "devices":
            done(devices())
        case "meter":
            let on: Bool = a["on"] as? Bool ?? false
            if !on {
                if file == nil { stopEngine() }
                done(true); return
            }
            access { ok in
                if !ok { done(["err": "没有音频输入权限：请在系统设置里允许 ABandOn 使用麦克风"]); return }
                do { try self.ensureRunning(dev); done(true) } catch { done(["err": error.localizedDescription]) }
            }
        case "start":
            access { ok in
                if !ok { done(["err": "没有音频输入权限：请在系统设置里允许 ABandOn 使用麦克风"]); return }
                do { try self.ensureRunning(dev); try self.beginFile(); done(["ok": true]) } catch { done(["err": error.localizedDescription]) }
            }
        case "stop":
            done(endFile())
        case "read":
            guard let u = last, let d = try? Data(contentsOf: u) else { done(["err": "没有录音文件"]); return }
            done(d.base64EncodedString())
        case "save":
            guard let u = last, let dest = Library.url(a["path"] as? String ?? "") else { done(["err": "路径无效"]); return }
            do {
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                try FileManager.default.copyItem(at: u, to: dest)
                done(Library.rel(dest))
            } catch { done(["err": error.localizedDescription]) }
        case "discard":
            if let u = last { try? FileManager.default.removeItem(at: u) }
            done(true)
        default:
            done(["err": "未知命令"])
        }
    }
}
