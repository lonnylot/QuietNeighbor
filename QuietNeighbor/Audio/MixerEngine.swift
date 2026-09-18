import CoreAudio
import Foundation
import OSLog

/// Owns the live tap sessions and keeps them matched to discovered apps + preferences.
///
/// Map mutations take a short lock. Core Audio create/start/stop runs on a serial
/// queue *outside* that lock so the menu bar does not stall on HAL calls.
final class MixerEngine: @unchecked Sendable {
    private struct SyncRequest {
        var apps: [ResolvedAppIdentity]
        var preferences: [String: VolumePreference]
        var outputDeviceUID: String?
    }

    private let logger = Logger(subsystem: QuietNeighborApp.subsystem, category: "engine")
    private let lock = NSLock()
    private let workQueue = DispatchQueue(label: "com.lonnylot.QuietNeighbor.engine")
    private var sessions: [String: AppTapSession] = [:]
    private var errors: [String: String] = [:]
    private var pending: SyncRequest?
    private var lastOutputUID: String?
    private var onSettled: (() -> Void)?

    func setOnSettled(_ handler: @escaping () -> Void) {
        lock.lock()
        onSettled = handler
        lock.unlock()
    }

    func error(for key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return errors[key]
    }

    func isTapActive(for key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sessions[key]?.isRunning == true
    }

    /// Peak of tap samples since start, plus how long the session has been up.
    /// Used to detect unauthorized system-audio taps (zeros, no error).
    func captureSnapshot(for key: String) -> (peak: Float, runningFor: TimeInterval)? {
        lock.lock()
        let session = sessions[key]
        lock.unlock()
        guard let session, session.isRunning, let started = session.runningSince else {
            return nil
        }
        return (session.capturedPeak, Date().timeIntervalSince(started))
    }

    /// Immediate gain write for an already-running session. Does not create taps.
    func updateGain(for key: String, preference: VolumePreference) {
        lock.lock()
        let session = sessions[key]
        lock.unlock()
        let command = TapGain.ioCommand(for: preference)
        session?.setGain(volume: command.volume, muted: command.muted)
    }

    func sync(apps: [ResolvedAppIdentity], store: VolumeStore, outputDeviceUID: String?) {
        let preferences = Dictionary(
            uniqueKeysWithValues: apps.map { ($0.persistenceKey, store.preference(for: $0.persistenceKey)) }
        )
        lock.lock()
        pending = SyncRequest(apps: apps, preferences: preferences, outputDeviceUID: outputDeviceUID)
        lock.unlock()
        workQueue.async { [weak self] in
            self?.processPending()
        }
    }

    func stopAll() {
        workQueue.sync {
            lock.lock()
            pending = nil
            let active = Array(sessions.values)
            sessions.removeAll()
            errors.removeAll()
            lastOutputUID = nil
            lock.unlock()
            active.forEach { $0.stop() }
            SystemAudio.destroyOrphanedQuietNeighborAggregates()
        }
    }

    private func processPending() {
        while true {
            lock.lock()
            guard let request = pending else {
                lock.unlock()
                break
            }
            pending = nil
            lock.unlock()
            apply(request)
        }

        lock.lock()
        let settled = onSettled
        lock.unlock()
        if let settled {
            DispatchQueue.main.async(execute: settled)
        }
    }

    private func apply(_ request: SyncRequest) {
        let outputUID = request.outputDeviceUID.flatMap { $0.isEmpty ? nil : $0 }
        let appKeys = Set(request.apps.map(\.persistenceKey))

        var toStop: [AppTapSession] = []
        var toStart: [(ResolvedAppIdentity, VolumePreference)] = []
        var keepGain: [(AppTapSession, VolumePreference)] = []
        var outputChanged = false

        lock.lock()
        outputChanged = lastOutputUID != outputUID
        lastOutputUID = outputUID

        for (key, session) in sessions where !appKeys.contains(key) {
            toStop.append(session)
            sessions.removeValue(forKey: key)
            errors.removeValue(forKey: key)
        }

        guard let outputUID else {
            toStop.append(contentsOf: sessions.values)
            sessions.removeAll()
            for app in request.apps {
                let preference = request.preferences[app.persistenceKey] ?? .default
                if preference.needsTap {
                    errors[app.persistenceKey] = "No output device is available."
                }
            }
            lock.unlock()
            finishStops(toStop, sweepOrphans: true)
            return
        }

        for app in request.apps {
            let preference = request.preferences[app.persistenceKey] ?? .default
            if !preference.needsTap {
                if let session = sessions[app.persistenceKey] {
                    toStop.append(session)
                    sessions.removeValue(forKey: app.persistenceKey)
                }
                errors.removeValue(forKey: app.persistenceKey)
                continue
            }

            if app.processObjectIDs.isEmpty {
                if let session = sessions[app.persistenceKey] {
                    toStop.append(session)
                    sessions.removeValue(forKey: app.persistenceKey)
                }
                errors[app.persistenceKey] = "This app is not producing audio right now."
                continue
            }

            if let session = sessions[app.persistenceKey],
               session.isRunning,
               !outputChanged,
               session.outputDeviceUID == outputUID,
               Set(session.processObjectIDs) == Set(app.processObjectIDs) {
                keepGain.append((session, preference))
                errors.removeValue(forKey: app.persistenceKey)
                continue
            }

            if let session = sessions[app.persistenceKey] {
                toStop.append(session)
                sessions.removeValue(forKey: app.persistenceKey)
            }
            toStart.append((app, preference))
        }
        lock.unlock()

        for (session, preference) in keepGain {
            let command = TapGain.ioCommand(for: preference)
            session.setGain(volume: command.volume, muted: command.muted)
        }

        finishStops(toStop, sweepOrphans: outputChanged || !toStop.isEmpty)

        for (app, preference) in toStart {
            let session = AppTapSession(
                persistenceKey: app.persistenceKey,
                processObjectIDs: app.processObjectIDs,
                outputDeviceUID: outputUID
            )
            do {
                let command = TapGain.ioCommand(for: preference)
                try session.start(volume: command.volume, muted: command.muted)
                lock.lock()
                sessions[app.persistenceKey] = session
                errors.removeValue(forKey: app.persistenceKey)
                lock.unlock()
            } catch {
                session.stop()
                let message = Self.friendlyMessage(for: error)
                lock.lock()
                errors[app.persistenceKey] = message
                lock.unlock()
                logger.error("Tap failed for \(app.persistenceKey, privacy: .public): \(message, privacy: .public)")
            }
        }
    }

    private func finishStops(_ sessions: [AppTapSession], sweepOrphans: Bool) {
        sessions.forEach { $0.stop() }
        if sweepOrphans {
            SystemAudio.destroyOrphanedQuietNeighborAggregates()
        }
    }

    private static func friendlyMessage(for error: Error) -> String {
        guard let audioError = error as? CoreAudioError else {
            return error.localizedDescription
        }
        switch audioError {
        case .invalidObject(let message):
            return message
        case .status(let status, let operation):
            let formatted = CoreAudioError.format(status)
            if formatted.contains("!pri") || formatted.contains("perm") {
                return "Audio capture was refused for this app. Allow Microphone and Screen & System Audio Recording."
            }
            if status == kAudioHardwareIllegalOperationError || status == kAudioHardwareBadObjectError {
                return "Could not tap this app. It may have quit or stopped playing."
            }
            return "Could not start per-app volume (\(operation): \(formatted))."
        }
    }
}
