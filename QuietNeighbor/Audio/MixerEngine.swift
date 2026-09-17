import Foundation
import OSLog

/// Owns the live tap sessions and keeps them matched to discovered apps + preferences.
final class MixerEngine: @unchecked Sendable {
    private let logger = Logger(subsystem: QuietNeighborApp.subsystem, category: "engine")
    private let lock = NSLock()
    private var sessions: [String: AppTapSession] = [:]
    private var errors: [String: String] = [:]

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

    func sync(apps: [ResolvedAppIdentity], store: VolumeStore, outputDeviceUID: String?) {
        lock.lock()
        defer { lock.unlock() }

        let keys = Set(apps.map(\.persistenceKey))
        for key in sessions.keys where !keys.contains(key) {
            sessions[key]?.stop()
            sessions.removeValue(forKey: key)
            errors.removeValue(forKey: key)
        }

        guard let outputDeviceUID, !outputDeviceUID.isEmpty else { return }

        for app in apps {
            let preference = store.preference(for: app.persistenceKey)
            let shouldTap = preference.needsTap && !app.processObjectIDs.isEmpty
            if shouldTap {
                applyTap(for: app, preference: preference, outputDeviceUID: outputDeviceUID)
            } else if let session = sessions[app.persistenceKey] {
                session.stop()
                sessions.removeValue(forKey: app.persistenceKey)
                errors.removeValue(forKey: app.persistenceKey)
            }
        }
    }

    func updateGain(for key: String, preference: VolumePreference) {
        lock.lock()
        defer { lock.unlock() }
        sessions[key]?.setGain(Float(preference.effectiveGain), muted: preference.isMuted)
    }

    func stopAll() {
        lock.lock()
        defer { lock.unlock() }
        for session in sessions.values {
            session.stop()
        }
        sessions.removeAll()
        errors.removeAll()
    }

    private func applyTap(
        for app: ResolvedAppIdentity,
        preference: VolumePreference,
        outputDeviceUID: String
    ) {
        if let session = sessions[app.persistenceKey], session.isRunning {
            session.setGain(Float(preference.effectiveGain), muted: preference.isMuted)
            let sameOutput = session.outputDeviceUID == outputDeviceUID
            let sameProcesses = Set(session.processObjectIDs) == Set(app.processObjectIDs)
            if sameOutput && sameProcesses {
                errors.removeValue(forKey: app.persistenceKey)
                return
            }
            session.stop()
            sessions.removeValue(forKey: app.persistenceKey)
        }

        let session = AppTapSession(
            persistenceKey: app.persistenceKey,
            processObjectIDs: app.processObjectIDs,
            outputDeviceUID: outputDeviceUID
        )
        do {
            try session.start(gain: Float(preference.effectiveGain), muted: preference.isMuted)
            sessions[app.persistenceKey] = session
            errors.removeValue(forKey: app.persistenceKey)
        } catch {
            session.stop()
            errors[app.persistenceKey] = error.localizedDescription
            logger.error("Tap failed for \(app.persistenceKey, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
