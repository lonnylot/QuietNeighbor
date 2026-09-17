import AppKit
import Combine
import Darwin
import Foundation

@MainActor
final class MixerController: ObservableObject {
    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var permission: AudioCaptureAuthorization = AudioCapturePermission.status
    @Published private(set) var defaultOutputUID: String?
    @Published var lastError: String?

    let store = VolumeStore()
    private let monitor = AudioProcessMonitor()
    private let engine = MixerEngine()
    private var identities: [ResolvedAppIdentity] = []
    private var lastHeard: [String: Date] = [:]
    private var outputPoller: Timer?
    private var didStart = false
    private var isRequestingPermission = false

    func start() {
        guard !didStart else { return }
        didStart = true
        SystemAudio.destroyOrphanedQuietNeighborAggregates()
        permission = AudioCapturePermission.status
        refreshOutputDevice()

        engine.setOnSettled { [weak self] in
            Task { @MainActor in
                self?.publishApps()
            }
        }

        monitor.onChange = { [weak self] identities in
            Task { @MainActor in
                self?.handleIdentities(identities)
            }
        }
        monitor.onOutputDeviceChange = { [weak self] in
            Task { @MainActor in
                self?.refreshOutputDevice()
            }
        }
        monitor.start()

        outputPoller = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshOutputDevice()
            }
        }
    }

    func stop() {
        outputPoller?.invalidate()
        outputPoller = nil
        monitor.stop()
        engine.stopAll()
    }

    func requestPermission() {
        requestPermissionAndRetry()
    }

    func setVolume(_ volume: Double, for app: AudioApp) {
        store.setVolume(volume, for: app.persistenceKey)
        applyChange(for: app.persistenceKey)
    }

    func setMuted(_ isMuted: Bool, for app: AudioApp) {
        store.setMuted(isMuted, for: app.persistenceKey)
        applyChange(for: app.persistenceKey)
    }

    func refresh() {
        permission = AudioCapturePermission.status
        if permission.allowsTaps {
            lastError = nil
        }
        refreshOutputDevice()
        monitor.refresh()
        syncEngine()
        publishApps()
    }

    private func applyChange(for key: String) {
        let preference = store.preference(for: key)
        if preference.needsTap && permission != .authorized {
            publishApps()
            requestPermissionAndRetry()
            return
        }
        if engine.isTapActive(for: key) && preference.needsTap {
            engine.updateGain(for: key, preference: preference)
        }
        syncEngine()
        publishApps()
    }

    private func requestPermissionAndRetry() {
        guard !isRequestingPermission else { return }
        isRequestingPermission = true
        Task {
            let status = await AudioCapturePermission.request()
            permission = status
            isRequestingPermission = false
            if status.allowsTaps {
                lastError = nil
                syncEngine()
            } else if status == .denied {
                lastError = "Audio capture is denied. QuietNeighbor cannot change per-app volume until it is allowed in Privacy settings."
                engine.stopAll()
            } else {
                lastError = "Allow audio capture to apply per-app volume."
            }
            publishApps()
        }
    }

    private func handleIdentities(_ identities: [ResolvedAppIdentity]) {
        self.identities = identities
        let now = Date()
        for identity in identities where identity.isPlaying {
            lastHeard[identity.persistenceKey] = now
        }
        pruneLastHeard()
        refreshOutputDevice()
        syncEngine()
        publishApps()
    }

    private func refreshOutputDevice() {
        let uid = try? SystemAudio.defaultOutputDeviceUID()
        if uid != defaultOutputUID {
            defaultOutputUID = uid
            syncEngine()
        }
    }

    private func syncEngine() {
        permission = AudioCapturePermission.status
        guard permission.allowsTaps else { return }
        engine.sync(apps: identities, store: store, outputDeviceUID: defaultOutputUID)
    }

    private func publishApps() {
        let now = Date()
        let rows: [AudioApp] = identities.compactMap { identity in
            let heard = lastHeard[identity.persistenceKey]
            let preference = store.preference(for: identity.persistenceKey)
            let stillRunning = identity.pids.contains { isProcessAlive($0) }
            let recentlyHeard = heard.map { now.timeIntervalSince($0) < AudioApp.recentGrace } ?? false
            let keepForSavedTap = stillRunning && preference.needsTap
            guard identity.isPlaying || recentlyHeard || keepForSavedTap else { return nil }

            let icon: NSImage?
            if let bundleURL = identity.bundleURL {
                icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
            } else if let path = identity.executablePath {
                icon = NSWorkspace.shared.icon(forFile: path)
            } else {
                icon = nil
            }

            return AudioApp(
                persistenceKey: identity.persistenceKey,
                name: identity.name,
                bundleIdentifier: identity.bundleIdentifier,
                bundleURL: identity.bundleURL,
                icon: icon,
                processObjectIDs: identity.processObjectIDs,
                pids: identity.pids,
                isPlaying: identity.isPlaying,
                lastHeard: heard,
                volume: preference.clampedVolume,
                isMuted: preference.isMuted,
                tapActive: engine.isTapActive(for: identity.persistenceKey),
                tapError: rowError(for: identity, preference: preference)
            )
        }
        .sorted { lhs, rhs in
            if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying && !rhs.isPlaying }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        apps = rows
    }

    private func rowError(for identity: ResolvedAppIdentity, preference: VolumePreference) -> String? {
        if let engineError = engine.error(for: identity.persistenceKey) {
            return engineError
        }
        guard preference.needsTap else { return nil }
        switch permission {
        case .denied:
            return "Audio capture is denied."
        case .notDetermined:
            return "Grant audio capture to apply this level."
        case .authorized:
            if identity.processObjectIDs.isEmpty {
                return "This app is not producing audio right now."
            }
            return nil
        }
    }

    private func pruneLastHeard() {
        let cutoff = Date().addingTimeInterval(-AudioApp.recentGrace)
        lastHeard = lastHeard.filter { $0.value >= cutoff }
    }

    private func isProcessAlive(_ pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        if NSRunningApplication(processIdentifier: pid) != nil {
            return true
        }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        return proc_pidpath(pid, &path, UInt32(path.count)) > 0
    }
}
