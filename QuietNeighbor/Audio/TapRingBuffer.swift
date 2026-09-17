import Foundation

/// Single-producer / single-consumer interleaved stereo ring (L,R,L,R,…).
/// Capture IOProc writes; AUHAL render reads. No allocation after `allocate`.
struct TapRingBuffer {
    let samples: UnsafeMutablePointer<Float32>
    let capacity: Int
    let writeIndex: UnsafeMutablePointer<Int>
    let readIndex: UnsafeMutablePointer<Int>

    /// `sampleCapacity` is rounded up to a power of two. Must be ≥ 4.
    static func allocate(sampleCapacity: Int) -> TapRingBuffer {
        var capacity = max(4, sampleCapacity)
        var rounded = 1
        while rounded < capacity { rounded <<= 1 }
        capacity = rounded

        let samples = UnsafeMutablePointer<Float32>.allocate(capacity: capacity)
        samples.initialize(repeating: 0, count: capacity)
        let writeIndex = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        writeIndex.initialize(to: 0)
        let readIndex = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        readIndex.initialize(to: 0)
        return TapRingBuffer(
            samples: samples,
            capacity: capacity,
            writeIndex: writeIndex,
            readIndex: readIndex
        )
    }

    func deallocate() {
        samples.deinitialize(count: capacity)
        samples.deallocate()
        writeIndex.deinitialize(count: 1)
        writeIndex.deallocate()
        readIndex.deinitialize(count: 1)
        readIndex.deallocate()
    }

    var availableToRead: Int {
        let write = writeIndex.pointee
        let read = readIndex.pointee
        return write &- read
    }

    var availableToWrite: Int {
        capacity - availableToRead
    }

    /// Copies as many interleaved samples as fit. Returns samples written.
    @discardableResult
    func write(from source: UnsafePointer<Float32>, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let writable = min(count, max(0, availableToWrite))
        guard writable > 0 else { return 0 }
        let write = writeIndex.pointee
        for index in 0..<writable {
            samples[(write &+ index) & (capacity - 1)] = source[index]
        }
        writeIndex.pointee = write &+ writable
        return writable
    }

    /// Reads interleaved samples. Unfilled tail is zeroed. Returns samples read.
    @discardableResult
    func read(into destination: UnsafeMutablePointer<Float32>, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let readable = min(count, max(0, availableToRead))
        let read = readIndex.pointee
        for index in 0..<readable {
            destination[index] = samples[(read &+ index) & (capacity - 1)]
        }
        if readable < count {
            destination.advanced(by: readable).initialize(repeating: 0, count: count - readable)
        }
        readIndex.pointee = read &+ readable
        return readable
    }
}
