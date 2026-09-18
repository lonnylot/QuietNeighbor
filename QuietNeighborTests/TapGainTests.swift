import CoreAudio
import XCTest

final class TapGainTests: XCTestCase {
    func testLinearGainIsContinuousRelativeAmplitude() {
        let points: [(Double, Float32)] = [
            (0, 0),
            (0.01, 0.01),
            (0.25, 0.25),
            (0.5, 0.5),
            (0.75, 0.75),
            (0.99, 0.99),
            (1, 1)
        ]
        for (volume, expected) in points {
            XCTAssertEqual(
                TapGain.linear(volume: volume, isMuted: false),
                expected,
                accuracy: 0.0001,
                "\(Int((volume * 100).rounded()))% must stay audible as relative gain, not snap to mute"
            )
        }
        XCTAssertEqual(TapGain.linear(volume: 1.4, isMuted: false), 1)
        XCTAssertEqual(TapGain.linear(volume: -0.2, isMuted: false), 0)
    }

    func testMuteForcesSilenceAndUnmuteRestoresSlider() {
        XCTAssertEqual(TapGain.linear(volume: 0.5, isMuted: true), 0)
        XCTAssertEqual(TapGain.linear(volume: 1, isMuted: true), 0)
        XCTAssertEqual(TapGain.linear(volume: 0.5, isMuted: false), 0.5, accuracy: 0.0001)
        XCTAssertEqual(TapGain.linear(volume: 1, isMuted: false), 1)
    }

    func testHalfGainScalesInterleavedStereo() {
        let input = TempABL.interleaved([1, 0.5, -1, 0.25], channels: 2)
        let output = TempABL.interleaved([99, 99, 99, 99], channels: 2)
        defer {
            input.free()
            output.free()
        }

        TapGain.mix(input: input.list, output: output.list, gain: 0.5, inputBufferOffset: 0)

        XCTAssertEqual(output.samples(count: 4), [0.5, 0.25, -0.5, 0.125])
    }

    func testUnityGainCopiesSamples() {
        let input = TempABL.interleaved([0.2, -0.4], channels: 2)
        let output = TempABL.interleaved([0, 0], channels: 2)
        defer {
            input.free()
            output.free()
        }

        TapGain.mix(input: input.list, output: output.list, gain: 1, inputBufferOffset: 0)

        XCTAssertEqual(output.samples(count: 2), [0.2, -0.4])
    }

    func testZeroGainWritesSilence() {
        let input = TempABL.interleaved([1, 1, 1, 1], channels: 2)
        let output = TempABL.interleaved([7, 7, 7, 7], channels: 2)
        defer {
            input.free()
            output.free()
        }

        TapGain.mix(input: input.list, output: output.list, gain: 0, inputBufferOffset: 0)

        XCTAssertEqual(output.samples(count: 4), [0, 0, 0, 0])
    }

    func testInvalidOffsetFallsBackInsteadOfMuting() {
        let input = TempABL.interleaved([1, 1], channels: 2)
        let output = TempABL.interleaved([0, 0], channels: 2)
        defer {
            input.free()
            output.free()
        }

        TapGain.mix(input: input.list, output: output.list, gain: 0.5, inputBufferOffset: 8)

        XCTAssertEqual(output.samples(count: 2), [0.5, 0.5])
    }

    func testNonInterleavedHalfGain() {
        let input = TempABL.nonInterleaved([[1, -1], [0.4, 0.8]])
        let output = TempABL.nonInterleaved([[9, 9], [9, 9]])
        defer {
            input.free()
            output.free()
        }

        TapGain.mix(input: input.list, output: output.list, gain: 0.5, inputBufferOffset: 0)

        XCTAssertEqual(output.samples(buffer: 0, count: 2), [0.5, -0.5])
        XCTAssertEqual(output.samples(buffer: 1, count: 2), [0.2, 0.4])
    }

    func testSkipsLeadingHardwareInputBuffers() {
        let input = TempABL.nonInterleaved([[100, 100], [1, 0.5], [0.2, 0.4]])
        let output = TempABL.nonInterleaved([[0, 0], [0, 0]])
        defer {
            input.free()
            output.free()
        }

        TapGain.mix(input: input.list, output: output.list, gain: 0.5, inputBufferOffset: 1)

        XCTAssertEqual(output.samples(buffer: 0, count: 2), [0.5, 0.25])
        XCTAssertEqual(output.samples(buffer: 1, count: 2), [0.1, 0.2])
    }

    func testTapInputOffsetNeverConsumesTheWholeTap() {
        XCTAssertEqual(TapGain.inputBufferOffset(physicalInputBuffers: 0, aggregateInputBuffers: 2), 0)
        XCTAssertEqual(TapGain.inputBufferOffset(physicalInputBuffers: 2, aggregateInputBuffers: 4), 2)
        XCTAssertEqual(TapGain.inputBufferOffset(physicalInputBuffers: 2, aggregateInputBuffers: 2), 0)
        XCTAssertEqual(TapGain.inputBufferOffset(physicalInputBuffers: 8, aggregateInputBuffers: 2), 0)
    }

    func testIOCommandKeepsPartialSliderAudible() {
        let preference = VolumePreference(volume: 0.5, isMuted: false)
        let command = TapGain.ioCommand(for: preference)
        XCTAssertEqual(command.volume, 0.5, accuracy: 0.0001)
        XCTAssertFalse(command.muted)
        XCTAssertEqual(command.gain, 0.5, accuracy: 0.0001)
        XCTAssertNotEqual(command.gain, 0, "50% must not collapse to mute")
    }

    func testIOCommandMuteIsIndependentOfSlider() {
        let mutedHalf = TapGain.ioCommand(for: VolumePreference(volume: 0.5, isMuted: true))
        XCTAssertTrue(mutedHalf.muted)
        XCTAssertEqual(mutedHalf.gain, 0)
        XCTAssertEqual(mutedHalf.volume, 0.5, accuracy: 0.0001)

        let unmutedHalf = TapGain.ioCommand(for: VolumePreference(volume: 0.5, isMuted: false))
        XCTAssertFalse(unmutedHalf.muted)
        XCTAssertEqual(unmutedHalf.gain, 0.5, accuracy: 0.0001)
    }

    func testAggregateTapUIDPrefersAssignedDescriptionUUID() {
        XCTAssertEqual(
            TapGain.aggregateTapUID(assigned: "ASSIGNED-UUID", hardware: "hardware-uid"),
            "ASSIGNED-UUID"
        )
        XCTAssertEqual(
            TapGain.aggregateTapUID(assigned: nil, hardware: "hardware-uid"),
            "hardware-uid"
        )
        XCTAssertEqual(
            TapGain.aggregateTapUID(assigned: "   ", hardware: "hardware-uid"),
            "hardware-uid"
        )
        XCTAssertNil(TapGain.aggregateTapUID(assigned: nil, hardware: nil))
        XCTAssertNil(TapGain.aggregateTapUID(assigned: "", hardware: "  "))
    }

    func testCaptureAggregateHasNoOutputSubdevice() {
        let spec = TapGain.CaptureAggregateSpec(
            name: "QuietNeighbor com.apple.Music",
            aggregateUID: "com.lonnylot.QuietNeighbor.agg.test",
            tapUID: "ASSIGNED-UUID"
        )
        XCTAssertFalse(spec.includesOutputSubdevice)
        XCTAssertFalse(spec.isStacked)
        XCTAssertTrue(spec.isPrivate)
        XCTAssertTrue(spec.tapAutoStart)

        let dictionary = spec.asDictionary()
        XCTAssertEqual(dictionary[kAudioAggregateDeviceIsStackedKey] as? Bool, false)
        XCTAssertEqual(dictionary[kAudioAggregateDeviceIsPrivateKey] as? Bool, true)
        XCTAssertNil(dictionary[kAudioAggregateDeviceMainSubDeviceKey])
        XCTAssertNil(dictionary[kAudioAggregateDeviceClockDeviceKey])
        XCTAssertEqual(dictionary[kAudioAggregateDeviceTapAutoStartKey] as? Bool, true)
        let subdevices = dictionary[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]]
        XCTAssertEqual(subdevices?.count, 0)

        let taps = dictionary[kAudioAggregateDeviceTapListKey] as? [[String: Any]]
        XCTAssertEqual(taps?.count, 1)
        XCTAssertEqual(taps?.first?[kAudioSubTapUIDKey] as? String, "ASSIGNED-UUID")
        XCTAssertEqual(taps?.first?[kAudioSubTapDriftCompensationKey] as? Bool, true)
    }

    func testDeviceAliveFlag() {
        XCTAssertTrue(TapGain.isDeviceAlive(1))
        XCTAssertFalse(TapGain.isDeviceAlive(0))
        XCTAssertFalse(TapGain.isDeviceAlive(2))
    }

    func testHalfGainInterleavedTapToNonInterleavedOutput() {
        let input = TempABL.interleaved([1, 0.4, -1, 0.8], channels: 2)
        let output = TempABL.nonInterleaved([[9, 9], [9, 9]])
        defer {
            input.free()
            output.free()
        }

        TapGain.mix(input: input.list, output: output.list, gain: 0.5, inputBufferOffset: 0)

        XCTAssertEqual(output.samples(buffer: 0, count: 2), [0.5, -0.5])
        XCTAssertEqual(output.samples(buffer: 1, count: 2), [0.2, 0.4])
    }

    func testFlattenAndApplyIsThePlaybackPathAndStaysAudible() {
        let input = TempABL.interleaved([1, 0.4, -1, 0.8], channels: 2)
        let output = TempABL.nonInterleaved([[9, 9], [9, 9]])
        defer {
            input.free()
            output.free()
        }

        var interleaved = [Float32](repeating: 0, count: 4)
        let frames = interleaved.withUnsafeMutableBufferPointer { buffer in
            TapGain.flattenToInterleavedStereo(
                input: input.list,
                into: buffer.baseAddress!,
                maxFrames: 2
            )
        }
        XCTAssertEqual(frames, 2)
        XCTAssertEqual(Array(interleaved), [1, 0.4, -1, 0.8])

        let gain = TapGain.ioCommand(for: VolumePreference(volume: 0.5, isMuted: false)).gain
        XCTAssertEqual(gain, 0.5, accuracy: 0.0001)
        interleaved.withUnsafeBufferPointer { buffer in
            TapGain.applyInterleavedStereo(
                buffer.baseAddress!,
                frames: frames,
                gain: gain,
                to: output.list
            )
        }
        XCTAssertEqual(output.samples(buffer: 0, count: 2), [0.5, -0.5])
        XCTAssertEqual(output.samples(buffer: 1, count: 2), [0.2, 0.4])
    }

    func testRingThenApplyHalfGainIsNotSilence() {
        let ring = TapRingBuffer.allocate(sampleCapacity: 32)
        defer { ring.deallocate() }

        let captured: [Float32] = [1, -1, 0.5, 0.25]
        captured.withUnsafeBufferPointer { buffer in
            XCTAssertEqual(ring.write(from: buffer.baseAddress!, count: 4), 4)
        }

        var scratch = [Float32](repeating: 99, count: 4)
        let read = scratch.withUnsafeMutableBufferPointer { buffer in
            ring.read(into: buffer.baseAddress!, count: 4)
        }
        XCTAssertEqual(read, 4)
        XCTAssertEqual(scratch, captured)

        let output = TempABL.nonInterleaved([[0, 0], [0, 0]])
        defer { output.free() }
        scratch.withUnsafeBufferPointer { buffer in
            TapGain.applyInterleavedStereo(
                buffer.baseAddress!,
                frames: 2,
                gain: 0.5,
                to: output.list
            )
        }
        XCTAssertEqual(output.samples(buffer: 0, count: 2), [0.5, 0.25])
        XCTAssertEqual(output.samples(buffer: 1, count: 2), [-0.5, 0.125])
        XCTAssertFalse(output.samples(buffer: 0, count: 2).allSatisfy { $0 == 0 })
    }

    func testPartialGainPipelineFromPreferenceIsAudibleNotSilent() {
        let preference = VolumePreference(volume: 0.5, isMuted: false)
        let gain = TapGain.ioCommand(for: preference).gain
        XCTAssertGreaterThan(gain, 0)

        let input = TempABL.nonInterleaved([[1, -0.5], [0.8, 0.2]])
        let output = TempABL.nonInterleaved([[0, 0], [0, 0]])
        defer {
            input.free()
            output.free()
        }

        TapGain.mix(input: input.list, output: output.list, gain: gain, inputBufferOffset: 0)

        XCTAssertEqual(output.samples(buffer: 0, count: 2), [0.5, -0.25])
        XCTAssertEqual(output.samples(buffer: 1, count: 2), [0.4, 0.1])
        XCTAssertFalse(
            output.samples(buffer: 0, count: 2).allSatisfy { $0 == 0 }
                && output.samples(buffer: 1, count: 2).allSatisfy { $0 == 0 },
            "Partial slider must write scaled samples, not silence"
        )
    }

    func testSilentPlayingTapLooksUnauthorized() {
        let preference = VolumePreference(volume: 0.5, isMuted: false)
        XCTAssertTrue(
            TapGain.CaptureHealth.looksUnauthorized(
                capturedPeak: 0,
                runningFor: TapGain.CaptureHealth.grace,
                isPlaying: true,
                preference: preference
            ),
            "Zeros after grace while playing at 50% is the live unauthorized-tap symptom"
        )
    }

    func testCaptureHealthIgnoresMuteZeroVolumeAndWarmup() {
        let half = VolumePreference(volume: 0.5, isMuted: false)
        XCTAssertFalse(
            TapGain.CaptureHealth.looksUnauthorized(
                capturedPeak: 0,
                runningFor: 0.1,
                isPlaying: true,
                preference: half
            ),
            "Warm-up zeros are not a permission failure"
        )
        XCTAssertFalse(
            TapGain.CaptureHealth.looksUnauthorized(
                capturedPeak: 0,
                runningFor: 2,
                isPlaying: true,
                preference: VolumePreference(volume: 0.5, isMuted: true)
            )
        )
        XCTAssertFalse(
            TapGain.CaptureHealth.looksUnauthorized(
                capturedPeak: 0,
                runningFor: 2,
                isPlaying: true,
                preference: VolumePreference(volume: 0, isMuted: false)
            )
        )
        XCTAssertFalse(
            TapGain.CaptureHealth.looksUnauthorized(
                capturedPeak: 0,
                runningFor: 2,
                isPlaying: false,
                preference: half
            )
        )
        XCTAssertFalse(
            TapGain.CaptureHealth.looksUnauthorized(
                capturedPeak: 0,
                runningFor: 2,
                isPlaying: true,
                preference: .default
            )
        )
        XCTAssertFalse(
            TapGain.CaptureHealth.looksUnauthorized(
                capturedPeak: 0.02,
                runningFor: 2,
                isPlaying: true,
                preference: half
            )
        )
    }

    func testCapturePeakUsesAbsoluteMagnitude() {
        var samples: [Float32] = [0.1, -0.8, 0.25]
        XCTAssertEqual(
            samples.withUnsafeBufferPointer { TapGain.CaptureHealth.peak(of: $0.baseAddress!, count: 0) },
            0
        )
        samples = [0, 0, 0]
        XCTAssertEqual(
            samples.withUnsafeBufferPointer { TapGain.CaptureHealth.peak(of: $0.baseAddress!, count: 3) },
            0
        )
        samples = [0.1, -0.8, 0.25]
        XCTAssertEqual(
            samples.withUnsafeBufferPointer { TapGain.CaptureHealth.peak(of: $0.baseAddress!, count: 3) },
            0.8,
            accuracy: 0.0001
        )
    }
}

/// Heap `AudioBufferList` for gain tests. Mirrors HAL interleaved (1 buffer, N
/// channels) and non-interleaved (N buffers, 1 channel) layouts.
private struct TempABL {
    let list: UnsafeMutableAudioBufferListPointer
    let storage: [UnsafeMutablePointer<Float>]

    static func interleaved(_ samples: [Float], channels: Int) -> TempABL {
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: samples.count)
        pointer.initialize(from: samples, count: samples.count)
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        list[0] = AudioBuffer(
            mNumberChannels: UInt32(channels),
            mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(pointer)
        )
        return TempABL(list: list, storage: [pointer])
    }

    static func nonInterleaved(_ channels: [[Float]]) -> TempABL {
        let list = AudioBufferList.allocate(maximumBuffers: channels.count)
        var storage: [UnsafeMutablePointer<Float>] = []
        for (index, samples) in channels.enumerated() {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: samples.count)
            pointer.initialize(from: samples, count: samples.count)
            storage.append(pointer)
            list[index] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(pointer)
            )
        }
        return TempABL(list: list, storage: storage)
    }

    func samples(buffer: Int = 0, count: Int) -> [Float] {
        Array(UnsafeBufferPointer(start: storage[buffer], count: count))
    }

    func free() {
        storage.forEach { $0.deallocate() }
        list.unsafeMutablePointer.deallocate()
    }
}
