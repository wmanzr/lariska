import AVFoundation
import CoreAudio
import Foundation
import LariskaCore
import Synchronization

/// Microphone resampled to 16 kHz mono, the speech analyser's format.
final class Microphone {
    enum Failure: Error, CustomStringConvertible {
        case denied, unavailable
        var description: String { self == .denied ? "нет доступа к микрофону" : "микрофон недоступен" }
    }

    private let engine = AVAudioEngine()
    private let buffer = Mutex([Float]())

    /// Asks once; the system remembers the answer for the terminal app.
    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    func start(sampleRate: Double) throws {
        let input = engine.inputNode
        let source = input.outputFormat(forBus: 0)
        guard source.sampleRate > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target) else { throw Failure.unavailable }
        input.installTap(onBus: 0, bufferSize: 2048, format: source) { [weak self] chunk, _ in
            let capacity = AVAudioFrameCount(Double(chunk.frameLength) * sampleRate / source.sampleRate) + 32
            guard let self, let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false
            converter.convert(to: out, error: nil) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return chunk
            }
            guard let channel = out.floatChannelData?[0] else { return }
            let samples = UnsafeBufferPointer(start: channel, count: Int(out.frameLength))
            self.buffer.withLock { $0.append(contentsOf: samples) }
        }
        do { try engine.start() } catch { input.removeTap(onBus: 0); throw Failure.unavailable }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Everything captured since the last call.
    func drain() -> [Float] { buffer.withLock { b in defer { b.removeAll(keepingCapacity: true) }; return b } }
}

/// Whether the Mac's own speakers are silent: the proof that what you hear is the trackpad.
enum SpeakerStatus {
    /// true: muted or at zero volume, false: audible, nil: unknown.
    static func isSilent() -> Bool? {
        guard let device: AudioObjectID = property(AudioObjectID(kAudioObjectSystemObject),
                                                   kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
        else { return nil }
        if let muted: UInt32 = property(device, kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput), muted != 0 { return true }
        for channel in [kAudioObjectPropertyElementMain, 1] {
            if let volume: Float32 = property(device, kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, channel) {
                return volume < 0.001
            }
        }
        return nil
    }

    private static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                    _ scope: AudioObjectPropertyScope,
                                    _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, storage) == noErr else { return nil }
        return storage.load(as: T.self)
    }
}

/// macOS text-to-speech rendered to samples.
enum SpeechSynth {
    enum Failure: Error, CustomStringConvertible {
        case noVoice(String), failed
        var description: String {
            switch self {
            case let .noVoice(name): "нет голоса «\(name)» (список: say -v '?')"
            case .failed: "say не смог произнести фразу"
            }
        }
    }

    static func hasVoice(_ name: String) -> Bool {
        AVSpeechSynthesisVoice.speechVoices().contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Longest a single `say` run may take before it is abandoned.
    static let timeout = 20.0

    /// Mono samples at `sampleRate`. Text goes through stdin, so a phrase can't be mistaken for an option.
    /// `cancelled` is polled while `say` runs; a cancelled or overdue run is terminated.
    static func render(_ text: String, voice: String, rate: Int, sampleRate: Double,
                       cancelled: () -> Bool = { false }) throws -> [Float] {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lariska-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: file) }
        let say = Process(), input = Pipe()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", voice, "-r", String(rate), "-o", file.path,
                         "--file-format=WAVE", "--data-format=LEF32@\(Int(sampleRate))", "-f", "-"]
        say.standardInput = input
        say.standardOutput = FileHandle.nullDevice
        say.standardError = FileHandle.nullDevice
        do { try say.run() } catch { throw Failure.failed }
        // A voice `say` rejects exits before reading; writing then fails with EPIPE, which must not kill us.
        do { try input.fileHandleForWriting.write(contentsOf: Data(text.utf8)) } catch { say.terminate() }
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(timeout)
        while say.isRunning {
            if cancelled() { say.terminate(); say.waitUntilExit(); throw CancellationError() }
            if Date() > deadline { say.terminate(); say.waitUntilExit(); throw Failure.failed }
            usleep(10_000)
        }
        guard say.terminationStatus == 0,
              let audio = try? AVAudioFile(forReading: file),
              let pcm = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)),
              (try? audio.read(into: pcm)) != nil,
              let channel = pcm.floatChannelData?[0] else { throw Failure.failed }
        return Array(UnsafeBufferPointer(start: channel, count: Int(pcm.frameLength)))
    }
}
