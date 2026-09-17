import AudioToolbox
import CoreAudio
import Foundation
import OSLog

/// Real-time parameters read by the HAL IOProc. Keep this a POD so the render
/// callback never allocates, locks, or touches Objective-C.
struct TapRenderState {
    var gain: Float32
    var muted: Int32
    var inputBufferOffset: Int32
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
        self.state.initialize(to: TapRenderState(gain: 1, muted: 0, inputBufferOffset: 0))
    }

    deinit {
        stop()
        state.deinitialize(count: 1)
        state.deallocate()
    }

    func setGain(volume: Float, muted: Bool) {
        state.pointee.gain = TapGain.linear(volume: Double(volume), isMuted: muted)
        state.pointee.muted = muted ? 1 : 0
    }

    func start(volume: Float, muted: Bool) throws {
        guard !isRunning else {
            setGain(volume: volume, muted: muted)
            return
        }
        setGain(volume: volume, muted: muted)
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
        // HAL's assigned tap UID is what the aggregate tap list must reference.
        // Using the Swift UUID string can miss the tap (case / assigned-id
        // mismatch) → muted original path + silent IOProc for every gain < 1.
        let tapUID: String
        if let uid = try? AudioProperty.readString(tapID, kAudioTapPropertyUID), !uid.isEmpty {
            tapUID = uid
        } else if let tapDescriptionUUID {
            tapUID = tapDescriptionUUID.uuidString
        } else {
            throw CoreAudioError.invalidObject("Process tap has no UID")
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

        // Duplex outputs (AirPods, USB interfaces) may prepend hardware input
        // streams. Only skip those when they actually appear on the aggregate —
        // otherwise the IOProc walks past the tap and plays silence.
        let physicalOutput = deviceID(forUID: outputDeviceUID)
        let physicalInputs = physicalOutput.map { SystemAudio.inputBufferCount(for: $0) } ?? 0
        let aggregateInputs = SystemAudio.inputBufferCount(for: aggregateID)
        state.pointee.inputBufferOffset = Int32(
            TapGain.inputBufferOffset(
                physicalInputBuffers: physicalInputs,
                aggregateInputBuffers: aggregateInputs
            )
        )

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
        let gain = s.muted != 0 ? Float32(0) : s.gain
        TapGain.mix(
            input: inList,
            output: outList,
            gain: gain,
            inputBufferOffset: Int(s.inputBufferOffset)
        )
    }
}
