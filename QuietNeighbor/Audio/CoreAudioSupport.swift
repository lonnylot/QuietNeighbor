import CoreAudio
import Darwin
import Foundation

enum CoreAudioError: Error, LocalizedError, Equatable {
    case status(OSStatus, operation: String)
    case invalidObject(String)

    var errorDescription: String? {
        switch self {
        case .status(let status, let operation):
            return "\(operation) failed (\(Self.format(status)))"
        case .invalidObject(let message):
            return message
        }
    }

    static func format(_ status: OSStatus) -> String {
        if status == noErr { return "noErr" }
        let value = UInt32(bitPattern: status)
        let bytes = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        if bytes.allSatisfy({ (32...126).contains($0) }),
           let code = String(bytes: bytes, encoding: .ascii) {
            return "'\(code)' (\(status))"
        }
        return "\(status)"
    }
}

enum AudioProperty {
    static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw CoreAudioError.status(status, operation: operation)
        }
    }

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func read<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> T {
        var property = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        try check(
            AudioObjectGetPropertyData(object, &property, 0, nil, &size, pointer),
            "read \(fourCC(selector))"
        )
        return pointer.move()
    }

    static func readArray<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> [T] {
        var property = address(selector, scope: scope)
        var size: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size),
            "size \(fourCC(selector))"
        )
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { pointer.deallocate() }
        try check(
            AudioObjectGetPropertyData(object, &property, 0, nil, &size, pointer),
            "read \(fourCC(selector))"
        )
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    static func readString(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> String {
        var property = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        try check(
            AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value),
            "read \(fourCC(selector))"
        )
        guard let value else {
            throw CoreAudioError.invalidObject("nil string for \(fourCC(selector))")
        }
        return value.takeRetainedValue() as String
    }

    static func fourCC(_ value: UInt32) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        if bytes.allSatisfy({ (32...126).contains($0) }),
           let code = String(bytes: bytes, encoding: .ascii) {
            return code
        }
        return String(value)
    }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    var isValid: Bool {
        self != kAudioObjectUnknown
    }
}

enum SystemAudio {
    static func defaultOutputDeviceID() throws -> AudioObjectID {
        let id: AudioObjectID = try AudioProperty.read(
            .system,
            kAudioHardwarePropertyDefaultOutputDevice
        )
        guard id.isValid else {
            throw CoreAudioError.invalidObject("No default output device")
        }
        return id
    }

    static func defaultOutputDeviceUID() throws -> String {
        let device = try defaultOutputDeviceID()
        return try AudioProperty.readString(device, kAudioDevicePropertyDeviceUID)
    }

    static func processObjectIDs() throws -> [AudioObjectID] {
        try AudioProperty.readArray(.system, kAudioHardwarePropertyProcessObjectList)
    }

    static func inputBufferCount(for device: AudioObjectID) -> Int {
        var property = AudioProperty.address(
            kAudioDevicePropertyStreamConfiguration,
            scope: kAudioObjectPropertyScopeInput
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, raw) == noErr else {
            return 0
        }
        return Int(raw.assumingMemoryBound(to: AudioBufferList.self).pointee.mNumberBuffers)
    }

    static func virtualFormat(
        device: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) throws -> AudioStreamBasicDescription {
        let streams: [AudioObjectID] = try AudioProperty.readArray(
            device,
            kAudioDevicePropertyStreams,
            scope: scope
        )
        guard let stream = streams.first else {
            throw CoreAudioError.invalidObject("Device has no streams for scope \(scope)")
        }
        return try AudioProperty.read(stream, kAudioStreamPropertyVirtualFormat)
    }

    static func isDeviceAlive(_ device: AudioObjectID) -> Bool {
        var property = AudioProperty.address(kAudioDevicePropertyDeviceIsAlive)
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &property, 0, nil, &size, &alive)
        return status == noErr && TapGain.isDeviceAlive(alive)
    }

    /// Stacked tap aggregates can take a beat to come up. Starting IO before
    /// `DeviceIsAlive` yields empty buffers after `mutedWhenTapped` has
    /// already silenced the original hardware path.
    static func waitUntilAlive(
        _ device: AudioObjectID,
        attempts: Int = 25,
        interval: TimeInterval = 0.02
    ) {
        for _ in 0..<attempts {
            if isDeviceAlive(device) { return }
            Thread.sleep(forTimeInterval: interval)
        }
    }

    static func destroyOrphanedQuietNeighborAggregates() {
        let devices: [AudioObjectID]
        do {
            devices = try AudioProperty.readArray(.system, kAudioHardwarePropertyDevices)
        } catch {
            return
        }
        for device in devices {
            guard let uid = try? AudioProperty.readString(device, kAudioDevicePropertyDeviceUID),
                  uid.hasPrefix(AppTapSession.aggregateUIDPrefix) else {
                continue
            }
            AudioHardwareDestroyAggregateDevice(device)
        }
    }
}

extension AudioStreamBasicDescription {
    var isFloat32PCM: Bool {
        mFormatID == kAudioFormatLinearPCM
            && (mFormatFlags & kAudioFormatFlagIsFloat) != 0
            && mBitsPerChannel == 32
    }

    var isNonInterleaved: Bool {
        (mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    }
}
