import Foundation

/// Persists per-app volume and mute, keyed by bundle id (or a stable fallback).
final class VolumeStore: @unchecked Sendable {
    static let defaultsKey = "quietNeighbor.volumeByApp"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var items: [String: VolumePreference]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: VolumePreference].self, from: data) {
            items = decoded
        } else {
            items = [:]
        }
    }

    func preference(for key: String) -> VolumePreference {
        lock.lock()
        defer { lock.unlock() }
        return items[key] ?? .default
    }

    func setVolume(_ volume: Double, for key: String) {
        update(key) { $0.volume = min(1, max(0, volume)) }
    }

    func setMuted(_ isMuted: Bool, for key: String) {
        update(key) { $0.isMuted = isMuted }
    }

    func allPreferences() -> [String: VolumePreference] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    private func update(_ key: String, mutate: (inout VolumePreference) -> Void) {
        lock.lock()
        var preference = items[key] ?? .default
        mutate(&preference)
        if preference == .default {
            items.removeValue(forKey: key)
        } else {
            items[key] = preference
        }
        let snapshot = items
        lock.unlock()
        persist(snapshot)
    }

    private func persist(_ snapshot: [String: VolumePreference]) {
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
