import Foundation
import AVFoundation

/// Captures microphone audio using AVAudioEngine, resamples to 16kHz mono,
/// and delivers Int16 little-endian PCM data via the `onAudioData` callback.
///
/// Two capture modes:
///   - `.live`     — PCM is forwarded to `onAudioData` immediately. Used by
///                   `startCapture()` (the legacy entry point).
///   - `.buffered` — PCM is retained in an in-memory ring buffer until the
///                   caller either commits (flushes buffered chunks through
///                   `onAudioData` and switches to live) or discards (drops
///                   buffered chunks and stops the engine). Used by the
///                   shortcut layer to keep Hold responsive without
///                   connecting the ASR for taps that turn out to be
///                   (double) taps.
class AudioCaptureManager {
    private enum CaptureMode {
        case live
        case buffered
    }

    private var audioEngine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var isCapturing = false

    private let gateLock = NSLock()
    private var captureMode: CaptureMode = .live
    private var bufferedChunks: [Data] = []
    private var bufferedBytes: Int = 0
    private var maxBufferedBytes: Int = 0

    /// Called on the audio thread with raw Int16 LE PCM data ready to send over WebSocket.
    var onAudioData: ((Data) -> Void)?
    var onRMS: ((Double) -> Void)?

    /// Starts microphone capture in live mode — PCM is forwarded immediately.
    func startCapture() throws {
        gateLock.lock()
        captureMode = .live
        bufferedChunks.removeAll()
        bufferedBytes = 0
        maxBufferedBytes = 0
        gateLock.unlock()
        try startEngineIfNeeded()
    }

    /// Starts microphone capture in buffered mode. PCM is retained in memory
    /// (ring-trimmed to `maxBufferMilliseconds`) until the caller commits
    /// or discards. Safe to call while already capturing — switches the gate
    /// without restarting the engine.
    func startBuffered(maxBufferMilliseconds: Int) throws {
        let targetBytes = max(0, maxBufferMilliseconds) * 16_000 * 2 / 1000
        gateLock.lock()
        captureMode = .buffered
        bufferedChunks.removeAll()
        bufferedBytes = 0
        maxBufferedBytes = targetBytes
        gateLock.unlock()
        try startEngineIfNeeded()
    }

    /// Flushes buffered chunks through `onAudioData` in order, then switches
    /// to live mode so subsequent PCM flows straight through.
    func commitBuffered() {
        gateLock.lock()
        let chunks = bufferedChunks
        bufferedChunks.removeAll()
        bufferedBytes = 0
        captureMode = .live
        gateLock.unlock()

        guard let callback = onAudioData else { return }
        for chunk in chunks {
            callback(chunk)
        }
    }

    /// Drops buffered chunks and stops the engine. Next use must call
    /// `startCapture()` or `startBuffered(...)` again.
    func discardBuffered() {
        gateLock.lock()
        bufferedChunks.removeAll()
        bufferedBytes = 0
        captureMode = .live
        gateLock.unlock()
        stopCapture()
    }

    func stopCapture() {
        guard isCapturing else { return }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        converter = nil
        isCapturing = false
        gateLock.lock()
        bufferedChunks.removeAll()
        bufferedBytes = 0
        captureMode = .live
        gateLock.unlock()
        print("[AudioCaptureManager] ⏹ Stopped")
    }

    // MARK: - Engine

    private func startEngineIfNeeded() throws {
        guard !isCapturing else { return }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "AudioCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No audio input available"])
        }

        // Target: 16kHz mono Float32 (converted to Int16 manually per doubao spec)
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        guard let conv = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(domain: "AudioCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create audio format converter"])
        }
        self.converter = conv

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) {
            [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }

        engine.prepare()
        try engine.start()

        self.audioEngine = engine
        self.isCapturing = true
        print("[AudioCaptureManager] ✅ Started (\(inputFormat.sampleRate)Hz ch\(inputFormat.channelCount) → 16kHz mono Int16)")
    }

    // MARK: - Audio Processing

    /// Resample native audio to 16kHz mono Float32, then convert to Int16 LE PCM.
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter = converter else { return }

        let ratio = 16000.0 / converter.inputFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio))
        guard outputFrameCapacity > 0,
              let outputBuffer = AVAudioPCMBuffer(
                  pcmFormat: converter.outputFormat,
                  frameCapacity: outputFrameCapacity
              ) else { return }

        var error: NSError?
        var hasInput = true
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if hasInput {
                hasInput = false
                outStatus.pointee = .haveData
                return buffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }

        guard status != .error, error == nil, outputBuffer.frameLength > 0 else { return }

        let floats = outputBuffer.floatChannelData![0]
        let count = Int(outputBuffer.frameLength)
        let rms = rmsValue(from: floats, count: count)
        onRMS?(rms)

        // Float32 → Int16 LE using doubao's non-symmetric scaling:
        //   negative samples × 32768, positive samples × 32767
        var pcm = Data(count: count * 2)
        pcm.withUnsafeMutableBytes { raw in
            let int16 = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                let s = floats[i]
                let v = s < 0 ? s * 32768.0 : s * 32767.0
                int16[i] = Int16(max(-32768, min(32767, v)))
            }
        }

        routePCM(pcm)
    }

    private func routePCM(_ pcm: Data) {
        gateLock.lock()
        switch captureMode {
        case .live:
            gateLock.unlock()
            onAudioData?(pcm)
        case .buffered:
            bufferedChunks.append(pcm)
            bufferedBytes += pcm.count
            // Ring-trim: drop oldest chunks when over budget so memory stays bounded.
            while bufferedBytes > maxBufferedBytes, bufferedChunks.count > 1 {
                let first = bufferedChunks.removeFirst()
                bufferedBytes -= first.count
            }
            gateLock.unlock()
        }
    }

    private func rmsValue(from buffer: UnsafePointer<Float>, count: Int) -> Double {
        guard count > 0 else { return 0 }
        var sum: Double = 0
        for index in 0..<count {
            let sample = Double(buffer[index])
            sum += sample * sample
        }
        return sqrt(sum / Double(count))
    }
}
