import AppKit
import CoreAudio
import Darwin
import Foundation
import OSLog

/// Discovers Core Audio process objects and groups helper/GPU processes under the owning app.
final class AudioProcessMonitor: @unchecked Sendable {
    private let logger = Logger(subsystem: QuietNeighborApp.subsystem, category: "monitor")
    private let queue = DispatchQueue(label: "com.lonnylot.QuietNeighbor.monitor")
    private var timer: DispatchSourceTimer?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var lastIdentities: [ResolvedAppIdentity] = []

    var onChange: (([ResolvedAppIdentity]) -> Void)?
    var onOutputDeviceChange: (() -> Void)?

    func start() {
        queue.async { [weak self] in
            self?.installListeners()
            self?.scan()
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1.0, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            self?.scan()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            removeListeners()
        }
    }

    func refresh() {
        queue.async { [weak self] in
            self?.scan()
        }
    }

    private func installListeners() {
        removeListeners()
        addListener(.system, kAudioHardwarePropertyProcessObjectList) { [weak self] in
            self?.scan()
        }
        addListener(.system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            self?.onOutputDeviceChange?()
            self?.scan()
        }
    }

    private func addListener(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        handler: @escaping () -> Void
    ) {
        var address = AudioProperty.address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            handler()
        }
        let status = AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
        if status == noErr {
            listeners.append((object, address, block))
        } else {
            logger.error("Failed to add listener \(AudioProperty.fourCC(selector), privacy: .public): \(status, privacy: .public)")
        }
    }

    private func removeListeners() {
        for (object, address, block) in listeners {
            var property = address
            AudioObjectRemovePropertyListenerBlock(object, &property, queue, block)
        }
        listeners.removeAll()
    }

    private func scan() {
        do {
            let identities = try discoverApps()
            guard identities != lastIdentities else { return }
            lastIdentities = identities
            onChange?(identities)
        } catch {
            logger.error("Process scan failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func discoverApps() throws -> [ResolvedAppIdentity] {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let selfBundle = Bundle.main.bundleIdentifier
        let objects = try SystemAudio.processObjectIDs()

        var grouped: [String: ResolvedAppIdentity] = [:]

        for objectID in objects {
            guard let pid: pid_t = try? AudioProperty.read(objectID, kAudioProcessPropertyPID),
                  pid > 1,
                  pid != selfPID else {
                continue
            }

            let isRunningOutput: UInt32 = (try? AudioProperty.read(objectID, kAudioProcessPropertyIsRunningOutput)) ?? 0
            let halBundle = try? AudioProperty.readString(objectID, kAudioProcessPropertyBundleID)
            if let selfBundle, halBundle == selfBundle { continue }

            let owner = ProcessIdentity.resolve(pid: pid, halBundleID: halBundle)
            if let selfBundle, owner.bundleIdentifier == selfBundle { continue }

            var entry = grouped[owner.persistenceKey] ?? ResolvedAppIdentity(
                persistenceKey: owner.persistenceKey,
                name: owner.name,
                bundleIdentifier: owner.bundleIdentifier,
                bundleURL: owner.bundleURL,
                executablePath: owner.executablePath,
                processObjectIDs: [],
                pids: [],
                isPlaying: false
            )
            if !entry.processObjectIDs.contains(objectID) {
                entry.processObjectIDs.append(objectID)
            }
            if !entry.pids.contains(pid) {
                entry.pids.append(pid)
            }
            if isRunningOutput != 0 {
                entry.isPlaying = true
            }
            grouped[owner.persistenceKey] = entry
        }

        return grouped.values
            .filter { !$0.processObjectIDs.isEmpty }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

enum ProcessIdentity {
    struct Owner: Equatable {
        var persistenceKey: String
        var name: String
        var bundleIdentifier: String?
        var bundleURL: URL?
        var executablePath: String?
    }

    static func resolve(pid: pid_t, halBundleID: String?) -> Owner {
        if let app = owningApplication(startingAt: pid) {
            let bundleID = app.bundleIdentifier ?? halBundleID
            let path = processPath(pid: app.processIdentifier) ?? processPath(pid: pid)
            let key: String
            if let bundleID, !bundleID.isEmpty {
                key = bundleID
            } else if let path, !path.isEmpty {
                key = "exe:\(path)"
            } else {
                key = "pid:\(app.processIdentifier)"
            }
            return Owner(
                persistenceKey: key,
                name: app.localizedName ?? processName(pid: pid) ?? bundleID ?? "Unknown app",
                bundleIdentifier: bundleID,
                bundleURL: app.bundleURL,
                executablePath: path
            )
        }

        let path = processPath(pid: pid)
        let name = processName(pid: pid)
        if let bundle = halBundleID, !bundle.isEmpty {
            return Owner(
                persistenceKey: bundle,
                name: name ?? bundle,
                bundleIdentifier: bundle,
                bundleURL: path.map { URL(fileURLWithPath: $0) },
                executablePath: path
            )
        }
        if let path, !path.isEmpty {
            return Owner(
                persistenceKey: "exe:\(path)",
                name: name ?? URL(fileURLWithPath: path).lastPathComponent,
                bundleIdentifier: nil,
                bundleURL: URL(fileURLWithPath: path),
                executablePath: path
            )
        }
        return Owner(
            persistenceKey: "pid:\(pid)",
            name: name ?? "Process \(pid)",
            bundleIdentifier: nil,
            bundleURL: nil,
            executablePath: nil
        )
    }

    private static func owningApplication(startingAt pid: pid_t) -> NSRunningApplication? {
        var ordered: [pid_t] = []
        var seen = Set<pid_t>()

        let responsible = responsiblePID(for: pid)
        if responsible > 1 {
            ordered.append(responsible)
        }

        var current: pid_t? = pid
        while let value = current, value > 1, !seen.contains(value) {
            seen.insert(value)
            ordered.append(value)
            current = parentPID(of: value)
        }

        let apps = ordered.compactMap { NSRunningApplication(processIdentifier: $0) }
        if let regular = apps.first(where: { app in
            app.activationPolicy == .regular
                && !isHelper(app.bundleIdentifier)
        }) {
            return regular
        }
        if let named = apps.first(where: { app in
            (app.bundleIdentifier != nil && !isHelper(app.bundleIdentifier)) || app.bundleURL != nil
        }) {
            return named
        }
        return apps.first
    }

    private static func isHelper(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        let hints = [
            ".helper", ".Helper", "WebKit.GPU", "WebKit.WebContent",
            "GPUHelper", "PluginHelper", "Renderer", "crashpad"
        ]
        return hints.contains { bundleID.contains($0) }
    }

    private static func responsiblePID(for pid: pid_t) -> pid_t {
        typealias Fn = @convention(c) (pid_t) -> pid_t
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid") else {
            return pid
        }
        let function = unsafeBitCast(symbol, to: Fn.self)
        let result = function(pid)
        return result > 0 ? result : pid
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdshortinfo()
        let size = MemoryLayout<proc_bsdshortinfo>.stride
        let written = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, Int32(size))
        guard written == Int32(size) else { return nil }
        let parent = pid_t(info.pbsi_ppid)
        return parent > 1 ? parent : nil
    }

    private static func processName(pid: pid_t) -> String? {
        var name = [CChar](repeating: 0, count: 1024)
        guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return nil }
        return String(cString: name)
    }

    private static func processPath(pid: pid_t) -> String? {
        var path = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return String(cString: path)
    }
}
