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
