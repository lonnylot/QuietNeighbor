import AudioToolbox
import CoreAudio
import Darwin
import Foundation
import OSLog

/// Real-time parameters read by the HAL IOProc. Keep this a POD so the render
/// callback never allocates, locks, or touches Objective-C.
struct TapRenderState {
    var gain: Float32
    var muted: Int32
    var inputBufferOffset: Int32
    var inputChannels: Int32
    var outputChannels: Int32
    var inputNonInterleaved: Int32
    var outputNonInterleaved: Int32
    var inputBytesPerFrame: Int32
    var outputBytesPerFrame: Int32
}

/// One intercepted app: muted Core Audio process tap → private aggregate → IOProc gain.
final class AppTapSession {
    static let aggregateUIDPrefix = "com.lonnylot.QuietNeighbor.agg."

    let persistenceKey: String
    private(set) var processObjectIDs: [AudioObjectID]
    private(set) var outputDeviceUID: String
    private(set) var isRunning = false

    private let logger: Logger
    private let ioQueue: DispatchQueue
    private let state: UnsafeMutablePointer<TapRenderState>

    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?
    private var tapDescriptionUUID: UUID?

    init(persistenceKey: String, processObjectIDs: [AudioObjectID], outputDeviceUID: String) {
        self.persistenceKey = persistenceKey
        self.processObjectIDs = processObjectIDs
        self.outputDeviceUID = outputDeviceUID
        self.logger = Logger(subsystem: QuietNeighborApp.subsystem, category: "tap.\(persistenceKey)")
        self.ioQueue = DispatchQueue(label: "com.lonnylot.QuietNeighbor.io.\(persistenceKey)")
        self.state = UnsafeMutablePointer<TapRenderState>.allocate(capacity: 1)
        self.state.initialize(
            to: TapRenderState(
                gain: 1,
                muted: 0,
                inputBufferOffset: 0,
                inputChannels: 2,
                outputChannels: 2,
                inputNonInterleaved: 0,
                outputNonInterleaved: 0,
                inputBytesPerFrame: 8,
                outputBytesPerFrame: 8
            )
        )
    }

    deinit {
        stop()
        state.deinitialize(count: 1)
        state.deallocate()
    }

    func setGain(_ gain: Float, muted: Bool) {
        state.pointee.gain = max(0, min(1, gain))
        state.pointee.muted = muted ? 1 : 0
    }

    func start(gain: Float, muted: Bool) throws {
        guard !isRunning else {
            setGain(gain, muted: muted)
            return
        }
        setGain(gain, muted: muted)
        do {
            try createTap()
            try createAggregate()
            try startIO()
            isRunning = true
            logger.info("Tap running for \(self.persistenceKey, privacy: .public)")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        let proc = ioProcID
        let aggregate = aggregateID
        let tap = tapID
        ioProcID = nil
        aggregateID = .unknown
        tapID = .unknown
        tapDescriptionUUID = nil
        isRunning = false

        if let proc, aggregate.isValid {
            AudioDeviceStop(aggregate, proc)
            AudioDeviceDestroyIOProcID(aggregate, proc)
        }
        if aggregate.isValid {
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        if tap.isValid {
            AudioHardwareDestroyProcessTap(tap)
        }
    }

    private func createTap() throws {
        guard !processObjectIDs.isEmpty else {
            throw CoreAudioError.invalidObject("No audio processes to tap for \(persistenceKey)")
        }

        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        let uuid = UUID()
        description.name = "QuietNeighbor – \(persistenceKey)"
        description.uuid = uuid
        description.isPrivate = true
        // Mute the original hardware path while this IOProc is reading, so we
        // don't hear the app twice. Audio returns to normal when the tap is destroyed.
        description.muteBehavior = .mutedWhenTapped

        var id = AudioObjectID.unknown
        try AudioProperty.check(
            AudioHardwareCreateProcessTap(description, &id),
            "AudioHardwareCreateProcessTap"
        )
        guard id.isValid else {
            throw CoreAudioError.invalidObject("Process tap returned an invalid object")
        }
        tapID = id
        tapDescriptionUUID = uuid
    }

    private func createAggregate() throws {
        let tapUID: String
        if let tapDescriptionUUID {
            tapUID = tapDescriptionUUID.uuidString
        } else {
            tapUID = try AudioProperty.readString(tapID, kAudioTapPropertyUID)
        }

        let uid = Self.aggregateUIDPrefix + UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "QuietNeighbor \(persistenceKey)",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID]
            ],
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        var id = AudioObjectID.unknown
        try AudioProperty.check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &id),
            "AudioHardwareCreateAggregateDevice"
        )
        guard id.isValid else {
            throw CoreAudioError.invalidObject("Aggregate device returned an invalid object")
        }
        aggregateID = id
    }

    private func startIO() throws {
        let tapFormat: AudioStreamBasicDescription = try AudioProperty.read(tapID, kAudioTapPropertyFormat)
        let outputFormat = try SystemAudio.virtualFormat(
            device: aggregateID,
            scope: kAudioObjectPropertyScopeOutput
        )

        guard tapFormat.isFloat32PCM, outputFormat.isFloat32PCM else {
            throw CoreAudioError.invalidObject(
                "Unsupported stream format (tap \(tapFormat.mBitsPerChannel)-bit, output \(outputFormat.mBitsPerChannel)-bit). QuietNeighbor requires 32-bit float PCM."
            )
        }

        // If the physical output is a duplex device, its input buffers precede the tap.
        let physicalOutput = deviceID(forUID: outputDeviceUID)
        let inputOffset = physicalOutput.map { SystemAudio.inputBufferCount(for: $0) } ?? 0

        state.pointee.inputBufferOffset = Int32(inputOffset)
        state.pointee.inputChannels = Int32(max(1, tapFormat.mChannelsPerFrame))
        state.pointee.outputChannels = Int32(max(1, outputFormat.mChannelsPerFrame))
        state.pointee.inputNonInterleaved = tapFormat.isNonInterleaved ? 1 : 0
        state.pointee.outputNonInterleaved = outputFormat.isNonInterleaved ? 1 : 0
        state.pointee.inputBytesPerFrame = Int32(tapFormat.mBytesPerFrame)
        state.pointee.outputBytesPerFrame = Int32(outputFormat.mBytesPerFrame)

        let state = self.state
        let block: AudioDeviceIOBlock = { _, inputData, _, outputData, _ in
            AppTapSession.render(input: inputData, output: outputData, state: state)
        }

        var procID: AudioDeviceIOProcID?
        try AudioProperty.check(
            AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue, block),
            "AudioDeviceCreateIOProcIDWithBlock"
        )
        ioProcID = procID
        try AudioProperty.check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
    }

    private func deviceID(forUID uid: String) -> AudioObjectID? {
        guard let devices: [AudioObjectID] = try? AudioProperty.readArray(
            .system,
            kAudioHardwarePropertyDevices
        ) else {
            return nil
        }
        return devices.first { device in
            (try? AudioProperty.readString(device, kAudioDevicePropertyDeviceUID)) == uid
        }
    }

    /// Real-time render: copy tap samples to the output device with gain. No allocation.
    private static func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        state: UnsafeMutablePointer<TapRenderState>
    ) {
        let s = state.pointee
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        for buffer in outList {
            if let data = buffer.mData, buffer.mDataByteSize > 0 {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }

        let gain: Float32 = s.muted != 0 ? 0 : s.gain
        if gain <= 0 { return }

        let inOffset = Int(s.inputBufferOffset)
        let inChannels = max(1, Int(s.inputChannels))
        let outChannels = max(1, Int(s.outputChannels))
        let inNonInterleaved = s.inputNonInterleaved != 0
        let outNonInterleaved = s.outputNonInterleaved != 0
        let inBytesPerFrame = Int(s.inputBytesPerFrame)
        let outBytesPerFrame = Int(s.outputBytesPerFrame)
        guard inBytesPerFrame > 0, outBytesPerFrame > 0 else { return }

        let inBuffersNeeded = inNonInterleaved ? inChannels : 1
        guard inList.count >= inOffset + inBuffersNeeded else { return }
        guard outList.count >= (outNonInterleaved ? outChannels : 1) else { return }
        guard let firstIn = inList[inOffset].mData, let firstOut = outList[0].mData else { return }

        let inFrames = Int(inList[inOffset].mDataByteSize) / inBytesPerFrame
        let outFrames = Int(outList[0].mDataByteSize) / outBytesPerFrame
        let frames = min(inFrames, outFrames)
        guard frames > 0 else { return }

        for frame in 0..<frames {
            for channel in 0..<outChannels {
                let sample: Float32
                if channel >= inChannels && inChannels <= 2 && channel >= 2 {
                    sample = 0
                } else {
                    let source = min(channel, inChannels - 1)
                    if inNonInterleaved {
                        guard let data = inList[inOffset + source].mData else { continue }
                        sample = data.assumingMemoryBound(to: Float32.self)[frame]
                    } else {
                        sample = firstIn.assumingMemoryBound(to: Float32.self)[frame * inChannels + source]
                    }
                }

                let value = sample * gain
                if outNonInterleaved {
                    if let data = outList[channel].mData {
                        data.assumingMemoryBound(to: Float32.self)[frame] = value
                    }
                } else {
                    firstOut.assumingMemoryBound(to: Float32.self)[frame * outChannels + channel] = value
                }
            }
        }
    }
}
