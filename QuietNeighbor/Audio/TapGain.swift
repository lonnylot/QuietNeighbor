import CoreAudio
import Darwin
import Foundation

/// Linear per-app gain versus system volume, plus the IOProc mix used when a tap
/// is active. Slider 0...1 is amplitude (50% = half as loud), not a mute gate.
enum TapGain {
    /// Relative amplitude written into the IOProc. Mute forces silence; unmute
    /// uses the saved slider. Values are continuous in 0...1 — never snapped
    /// to 0/1 except at the endpoints or when muted.
    static func linear(volume: Double, isMuted: Bool) -> Float32 {
        if isMuted { return 0 }
        return Float32(min(1, max(0, volume)))
    }

    /// Skip leading hardware-input buffers on a duplex aggregate, but never
    /// skip the whole tap. A physical device that reports as many (or more)
    /// input streams as the aggregate would otherwise make every `gain < 1`
    /// path write silence after `muteBehavior = .mutedWhenTapped`.
    static func inputBufferOffset(physicalInputBuffers: Int, aggregateInputBuffers: Int) -> Int {
        if physicalInputBuffers > 0, physicalInputBuffers < aggregateInputBuffers {
            return physicalInputBuffers
        }
        return 0
    }

    /// Copy tap samples onto the output device with linear gain.
    ///
    /// Layout is taken from the live `AudioBufferList` (`mNumberBuffers` /
    /// `mNumberChannels` / `mDataByteSize`), not from a tap ASBD. HAL IOProc
    /// buffers are typically non-interleaved even when `kAudioTapPropertyFormat`
    /// reports an interleaved mixdown — trusting the ASBD caused `mBytesPerFrame
    /// == 0` or a buffer-count mismatch, both of which used to early-return
    /// after the output was zeroed (full mute for any slider below 100%).
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
