import AudioToolbox
import CoreAudio
import Darwin
import Foundation
import OSLog

/// Real-time parameters read by the capture IOProc and AUHAL render.
struct TapRenderState {
    var gain: Float32
    var muted: Int32
}

struct TapPlaybackContext {
    var state: UnsafeMutablePointer<TapRenderState>
    var ring: TapRingBuffer
    var scratch: UnsafeMutablePointer<Float32>
    var scratchFrames: Int
}

/// One intercepted app: muted process tap → tap-only capture aggregate → ring
/// → AUHAL on the real output device (gain applied there).
///
/// Playing back through the same private aggregate that holds the tap was
/// verified silent on a live Mac after #4 and #6. Capture and playback are
/// separate HAL clients so `mutedWhenTapped` cannot swallow the replay.
final class AppTapSession {
    static let aggregateUIDPrefix = "com.lonnylot.QuietNeighbor.agg."
    static let ringSampleCapacity = 16_384
    static let flattenScratchFrames = 4_096

    let persistenceKey: String
    private(set) var processObjectIDs: [AudioObjectID]
    private(set) var outputDeviceUID: String
    private(set) var isRunning = false

    private let logger: Logger
    private let state: UnsafeMutablePointer<TapRenderState>
    private let ring: TapRingBuffer
    private let flattenScratch: UnsafeMutablePointer<Float32>
    private let playbackScratch: UnsafeMutablePointer<Float32>

    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?
    private var tapDescriptionUUID: UUID?
    private var outputUnit: AudioUnit?
    private var playbackContext: UnsafeMutablePointer<TapPlaybackContext>?

    init(persistenceKey: String, processObjectIDs: [AudioObjectID], outputDeviceUID: String) {
        self.persistenceKey = persistenceKey
        self.processObjectIDs = processObjectIDs
        self.outputDeviceUID = outputDeviceUID
        self.logger = Logger(subsystem: QuietNeighborApp.subsystem, category: "tap.\(persistenceKey)")
        self.state = UnsafeMutablePointer<TapRenderState>.allocate(capacity: 1)
        self.state.initialize(to: TapRenderState(gain: 1, muted: 0))
        self.ring = TapRingBuffer.allocate(sampleCapacity: Self.ringSampleCapacity)
        self.flattenScratch = UnsafeMutablePointer<Float32>.allocate(capacity: Self.flattenScratchFrames * 2)
        self.flattenScratch.initialize(repeating: 0, count: Self.flattenScratchFrames * 2)
        self.playbackScratch = UnsafeMutablePointer<Float32>.allocate(capacity: Self.flattenScratchFrames * 2)
        self.playbackScratch.initialize(repeating: 0, count: Self.flattenScratchFrames * 2)
    }

    deinit {
        stop()
        state.deinitialize(count: 1)
        state.deallocate()
        flattenScratch.deinitialize(count: Self.flattenScratchFrames * 2)
        flattenScratch.deallocate()
        playbackScratch.deinitialize(count: Self.flattenScratchFrames * 2)
        playbackScratch.deallocate()
        ring.deallocate()
    }

    func setGain(volume: Float, muted: Bool) {
        let command = TapGain.ioCommand(
            for: VolumePreference(volume: Double(volume), isMuted: muted)
        )
        state.pointee.gain = command.gain
        state.pointee.muted = command.muted ? 1 : 0
    }

    func start(volume: Float, muted: Bool) throws {
        guard !isRunning else {
            setGain(volume: volume, muted: muted)
            return
        }
        setGain(volume: volume, muted: muted)
        do {
            try createTap()
            try createCaptureAggregate()
            try attachTapList()
            try startCapture()
            try startPlayback()
            isRunning = true
            logger.info("Tap+AUHAL running for \(self.persistenceKey, privacy: .public)")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        let unit = outputUnit
        outputUnit = nil
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        if let playbackContext {
            playbackContext.deinitialize(count: 1)
            playbackContext.deallocate()
            self.playbackContext = nil
        }

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

    private func createCaptureAggregate() throws {
        let hardwareUID = try? AudioProperty.readString(tapID, kAudioTapPropertyUID)
        guard let tapUID = TapGain.aggregateTapUID(
            assigned: tapDescriptionUUID?.uuidString,
            hardware: hardwareUID
        ) else {
            throw CoreAudioError.invalidObject("Process tap has no UID")
        }

        let spec = TapGain.CaptureAggregateSpec(
            name: "QuietNeighbor \(persistenceKey)",
            aggregateUID: Self.aggregateUIDPrefix + UUID().uuidString,
            tapUID: tapUID
        )

        var id = AudioObjectID.unknown
        try AudioProperty.check(
            AudioHardwareCreateAggregateDevice(spec.asDictionary() as CFDictionary, &id),
            "AudioHardwareCreateAggregateDevice"
        )
        guard id.isValid else {
            throw CoreAudioError.invalidObject("Aggregate device returned an invalid object")
        }
        aggregateID = id
    }

    /// Apple's documented attach path: set `kAudioAggregateDevicePropertyTapList`
    /// on the aggregate after create. Creation-dictionary-only was not enough
    /// to get a live playback path on the user's Mac.
    private func attachTapList() throws {
        let assigned = tapDescriptionUUID?.uuidString
        let hardware = try? AudioProperty.readString(tapID, kAudioTapPropertyUID)
        var unique: [String] = []
        for uid in [assigned, hardware] {
            guard let uid, !uid.isEmpty, !unique.contains(uid) else { continue }
            unique.append(uid)
        }
        guard !unique.isEmpty else {
            throw CoreAudioError.invalidObject("Process tap has no UID to attach")
        }

        var address = AudioProperty.address(kAudioAggregateDevicePropertyTapList)
        let list = unique as CFArray
        var value: CFArray = list
        let size = UInt32(MemoryLayout<CFArray>.stride)
        let status = withUnsafePointer(to: &value) { pointer in
            AudioObjectSetPropertyData(aggregateID, &address, 0, nil, size, pointer)
        }
        if status != noErr {
            logger.error("set tap list failed (\(status, privacy: .public)); using creation-dictionary tap")
        }
    }

    private func startCapture() throws {
        let tapFormat: AudioStreamBasicDescription = try AudioProperty.read(tapID, kAudioTapPropertyFormat)
        guard tapFormat.isFloat32PCM else {
            throw CoreAudioError.invalidObject(
                "Unsupported tap format (\(tapFormat.mBitsPerChannel)-bit). QuietNeighbor requires 32-bit float PCM."
            )
        }

        if let output = deviceID(forUID: outputDeviceUID),
           let rate = try? SystemAudio.nominalSampleRate(of: output),
           rate > 0 {
            try? SystemAudio.setNominalSampleRate(rate, on: aggregateID)
        }

        SystemAudio.waitUntilAlive(aggregateID)

        let ring = self.ring
        let scratch = flattenScratch
        let maxFrames = Self.flattenScratchFrames
        // nil queue = HAL realtime thread. A GCD hop was a live-silence suspect.
        let block: AudioDeviceIOBlock = { _, inputData, _, _, _ in
            let input = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inputData)
            )
            let frames = TapGain.flattenToInterleavedStereo(
                input: input,
                into: scratch,
                maxFrames: maxFrames
            )
            if frames > 0 {
                ring.write(from: scratch, count: frames * 2)
            }
        }

        var procID: AudioDeviceIOProcID?
        try AudioProperty.check(
            AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil, block),
            "AudioDeviceCreateIOProcIDWithBlock"
        )
        ioProcID = procID
        try AudioProperty.check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
    }

    private func startPlayback() throws {
        guard let outputID = deviceID(forUID: outputDeviceUID) else {
            throw CoreAudioError.invalidObject("Could not find the current output device.")
        }

        let context = UnsafeMutablePointer<TapPlaybackContext>.allocate(capacity: 1)
        context.initialize(
            to: TapPlaybackContext(
                state: state,
                ring: ring,
                scratch: playbackScratch,
                scratchFrames: Self.flattenScratchFrames
            )
        )
        playbackContext = context

        do {
            outputUnit = try HALPlayback.makeOutputUnit(
                deviceID: outputID,
                context: UnsafeMutableRawPointer(context)
            )
            try AudioProperty.check(AudioOutputUnitStart(outputUnit!), "AudioOutputUnitStart")
        } catch {
            context.deinitialize(count: 1)
            context.deallocate()
            playbackContext = nil
            throw error
        }
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
}

enum HALPlayback {
    static func makeOutputUnit(
        deviceID: AudioObjectID,
        context: UnsafeMutableRawPointer
    ) throws -> AudioUnit {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CoreAudioError.invalidObject("HAL output audio unit is unavailable.")
        }

        var unit: AudioUnit?
        try AudioProperty.check(AudioComponentInstanceNew(component, &unit), "AudioComponentInstanceNew")
        guard let audioUnit = unit else {
            throw CoreAudioError.invalidObject("HAL output audio unit was nil.")
        }

        do {
            try configure(audioUnit, deviceID: deviceID, context: context)
            return audioUnit
        } catch {
            AudioComponentInstanceDispose(audioUnit)
            throw error
        }
    }

    private static func configure(
        _ audioUnit: AudioUnit,
        deviceID: AudioObjectID,
        context: UnsafeMutableRawPointer
    ) throws {
        var enableOutput: UInt32 = 1
        var disableInput: UInt32 = 0
        try AudioProperty.check(
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Output,
                0,
                &enableOutput,
                UInt32(MemoryLayout<UInt32>.size)
            ),
            "EnableIO output"
        )
        try AudioProperty.check(
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Input,
                1,
                &disableInput,
                UInt32(MemoryLayout<UInt32>.size)
            ),
            "EnableIO input"
        )

        var device = deviceID
        try AudioProperty.check(
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &device,
                UInt32(MemoryLayout<AudioObjectID>.size)
            ),
            "CurrentDevice"
        )

        let sampleRate = (try? SystemAudio.nominalSampleRate(of: deviceID)) ?? 48_000
        var stream = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        try AudioProperty.check(
            AudioUnitSetProperty(
                audioUnit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Input,
                0,
                &stream,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            ),
            "StreamFormat"
        )

        var callback = AURenderCallbackStruct(
            inputProc: render,
            inputProcRefCon: context
        )
        try AudioProperty.check(
            AudioUnitSetProperty(
                audioUnit,
                kAudioUnitProperty_SetRenderCallback,
                kAudioUnitScope_Input,
                0,
                &callback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ),
            "SetRenderCallback"
        )

        try AudioProperty.check(AudioUnitInitialize(audioUnit), "AudioUnitInitialize")
    }

    private static let render: AURenderCallback = { refCon, _, _, _, frameCount, ioData in
        guard let ioData, frameCount > 0 else { return noErr }
        let context = refCon.assumingMemoryBound(to: TapPlaybackContext.self).pointee
        let gain = context.state.pointee.muted != 0 ? Float32(0) : context.state.pointee.gain
        let frames = min(Int(frameCount), context.scratchFrames)
        _ = context.ring.read(into: context.scratch, count: frames * 2)
        let output = UnsafeMutableAudioBufferListPointer(ioData)
        TapGain.applyInterleavedStereo(
            context.scratch,
            frames: frames,
            gain: gain,
            to: output
        )
        return noErr
    }
}

