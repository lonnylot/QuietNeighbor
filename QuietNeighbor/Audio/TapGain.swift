import CoreAudio
import Darwin
import Foundation

/// Linear per-app gain versus system volume, plus the capture→playback helpers
/// used when a tap is active. Slider 0...1 is amplitude (50% = half as loud).
enum TapGain {
    /// Relative amplitude. Mute forces silence; unmute uses the saved slider.
    static func linear(volume: Double, isMuted: Bool) -> Float32 {
        if isMuted { return 0 }
        return Float32(min(1, max(0, volume)))
    }

    /// The command written into the realtime state. `volume < 1` is never mute.
    static func ioCommand(for preference: VolumePreference) -> (volume: Float, muted: Bool, gain: Float32) {
        let volume = Float(preference.clampedVolume)
        let muted = preference.isMuted
        return (volume, muted, linear(volume: Double(volume), isMuted: muted))
    }

    /// UID the aggregate tap list must reference. Prefer the UUID assigned on
    /// `CATapDescription`; HAL's property is fallback only.
    static func aggregateTapUID(assigned: String?, hardware: String?) -> String? {
        if let assigned, !assigned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return assigned
        }
        if let hardware, !hardware.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return hardware
        }
        return nil
    }

    /// Tap-only private aggregate used as a **capture** device.
    /// Playback goes through a separate AUHAL on the real output — this
    /// spec has no output subdevice.
    struct CaptureAggregateSpec: Equatable {
        var name: String
        var aggregateUID: String
        var tapUID: String

        var isPrivate: Bool { true }
        var isStacked: Bool { false }
        var tapAutoStart: Bool { true }
        var includesOutputSubdevice: Bool { false }

        func asDictionary() -> [String: Any] {
            [
                kAudioAggregateDeviceNameKey: name,
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceIsPrivateKey: isPrivate,
                kAudioAggregateDeviceIsStackedKey: isStacked,
                kAudioAggregateDeviceTapAutoStartKey: tapAutoStart,
                kAudioAggregateDeviceSubDeviceListKey: [] as [[String: Any]],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapUIDKey: tapUID,
                        kAudioSubTapDriftCompensationKey: true
                    ]
                ]
            ]
        }
    }

    static func isDeviceAlive(_ flag: UInt32) -> Bool {
        flag == 1
    }

    /// Unauthorized system-audio taps return zeros with no error — the
    /// symptom that looks like “slider below 100% mutes.”
    enum CaptureHealth {
        static let silenceThreshold: Float = 1e-5
        static let grace: TimeInterval = 0.75

        static func looksUnauthorized(
            capturedPeak: Float,
            runningFor: TimeInterval,
            isPlaying: Bool,
            preference: VolumePreference
        ) -> Bool {
            preference.needsTap
                && !preference.isMuted
                && preference.clampedVolume > 0
                && isPlaying
                && runningFor >= grace
                && capturedPeak < silenceThreshold
        }

        static func peak(of samples: UnsafePointer<Float32>, count: Int) -> Float32 {
            guard count > 0 else { return 0 }
            var peak: Float32 = 0
            for index in 0..<count {
                let magnitude = abs(samples[index])
                if magnitude > peak { peak = magnitude }
            }
            return peak
        }
    }

    static func inputBufferOffset(physicalInputBuffers: Int, aggregateInputBuffers: Int) -> Int {
        if physicalInputBuffers > 0, physicalInputBuffers < aggregateInputBuffers {
            return physicalInputBuffers
        }
        return 0
    }

    /// Copy live tap buffers into interleaved stereo (L,R,L,R,…).
    /// Empty leading hardware-input buffers are skipped.
    static func flattenToInterleavedStereo(
        input: UnsafeMutableAudioBufferListPointer,
        into destination: UnsafeMutablePointer<Float32>,
        maxFrames: Int
    ) -> Int {
        let sources = channels(in: input, startingAt: 0)
        guard !sources.isEmpty, maxFrames > 0 else { return 0 }
        let frames = min(maxFrames, sources.map(\.frames).min() ?? 0)
        guard frames > 0 else { return 0 }
        let left = sources[0]
        let right = sources[min(1, sources.count - 1)]
        for frame in 0..<frames {
            destination[frame * 2] = left.get(frame: frame)
            destination[frame * 2 + 1] = right.get(frame: frame)
        }
        return frames
    }

    /// Scale interleaved stereo and write into a live output ABL (interleaved
    /// or non-interleaved). This is the AUHAL playback path.
    static func applyInterleavedStereo(
        _ source: UnsafePointer<Float32>,
        frames: Int,
        gain: Float32,
        to output: UnsafeMutableAudioBufferListPointer
    ) {
        for buffer in output {
            if let data = buffer.mData, buffer.mDataByteSize > 0 {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
        let applied = max(0, gain)
        if applied <= 0 || frames <= 0 { return }

        let destinations = channels(in: output, startingAt: 0)
        guard !destinations.isEmpty else { return }
        let outFrames = min(frames, destinations.map(\.frames).min() ?? 0)
        guard outFrames > 0 else { return }

        for frame in 0..<outFrames {
            for (index, destination) in destinations.enumerated() {
                let channel = min(index, 1)
                destination.set(frame: frame, value: source[frame * 2 + channel] * applied)
            }
        }
    }

    /// Copy tap samples onto an output ABL with linear gain. Used by tests
    /// and as a fallback mixer for combined input/output buffer lists.
    static func mix(
        input: UnsafeMutableAudioBufferListPointer,
        output: UnsafeMutableAudioBufferListPointer,
        gain: Float32,
        inputBufferOffset: Int
    ) {
        for buffer in output {
            if let data = buffer.mData, buffer.mDataByteSize > 0 {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }

        let applied = max(0, gain)
        if applied <= 0 { return }

        let start: Int
        if inputBufferOffset >= 0, inputBufferOffset < input.count {
            start = inputBufferOffset
        } else {
            start = 0
        }

        let sources = channels(in: input, startingAt: start)
        let destinations = channels(in: output, startingAt: 0)
        guard !sources.isEmpty, !destinations.isEmpty else { return }

        let frames = min(sources.map(\.frames).min() ?? 0, destinations.map(\.frames).min() ?? 0)
        guard frames > 0 else { return }

        for frame in 0..<frames {
            for (index, destination) in destinations.enumerated() {
                let source = sources[min(index, sources.count - 1)]
                destination.set(frame: frame, value: source.get(frame: frame) * applied)
            }
        }
    }

    fileprivate struct Channel {
        let base: UnsafeMutablePointer<Float32>
        let stride: Int
        let frames: Int

        func get(frame: Int) -> Float32 {
            base[frame * stride]
        }

        func set(frame: Int, value: Float32) {
            base[frame * stride] = value
        }
    }

    fileprivate static func channels(
        in list: UnsafeMutableAudioBufferListPointer,
        startingAt start: Int
    ) -> [Channel] {
        guard start < list.count else { return [] }
        var result: [Channel] = []
        for index in start..<list.count {
            let buffer = list[index]
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else { continue }
            let channelCount = max(1, Int(buffer.mNumberChannels))
            let bytesPerFrame = channelCount * MemoryLayout<Float32>.size
            guard bytesPerFrame > 0 else { continue }
            let frames = Int(buffer.mDataByteSize) / bytesPerFrame
            guard frames > 0 else { continue }
            let samples = data.assumingMemoryBound(to: Float32.self)
            for channel in 0..<channelCount {
                result.append(
                    Channel(base: samples.advanced(by: channel), stride: channelCount, frames: frames)
                )
            }
        }
        return result
    }
}
