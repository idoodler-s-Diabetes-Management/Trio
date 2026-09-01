import Foundation

/// What Nocturne can sync. Health metrics are read from Apple Health by ``NocturneManager``;
/// the Nightscout-compatible metrics are mirrored by ``NightscoutManager`` whenever a Nocturne
/// connection is configured and "Upload Nightscout Data" is enabled, reusing the exact payloads
/// it already builds for Nightscout itself.
enum NocturneSyncMetric: String, CaseIterable {
    case heartRate
    case steps
    case sleep
    case glucose
    case treatments
    case deviceStatus
    case profile

    var displayName: String {
        switch self {
        case .heartRate: return String(localized: "Heart Rate")
        case .steps: return String(localized: "Steps")
        case .sleep: return String(localized: "Sleep")
        case .glucose: return String(localized: "Glucose")
        case .treatments: return String(localized: "Treatments")
        case .deviceStatus: return String(localized: "Device Status")
        case .profile: return String(localized: "Profile")
        }
    }

    /// Metrics sourced from Apple Health via HealthKit, rather than mirrored from Trio's own
    /// Nightscout-compatible upload pipeline.
    static let healthMetrics: [NocturneSyncMetric] = [.heartRate, .steps, .sleep]

    /// Metrics mirrored from the same data Trio sends to Nightscout.
    static let nightscoutMetrics: [NocturneSyncMetric] = [.glucose, .treatments, .deviceStatus, .profile]
}

/// Tracks, per metric, the last time Trio successfully uploaded data to Nocturne — both via the
/// regular incremental sync and via an explicit backfill. Backed by `UserDefaults` so it survives
/// relaunches without needing a Core Data migration; purely informational (drives the "What's
/// synced" section of the Nocturne settings screen), never read to gate upload behavior.
enum NocturneSyncStatus {
    private static func syncedKey(_ metric: NocturneSyncMetric) -> String {
        "NocturneSyncStatus.lastSynced.\(metric.rawValue)"
    }

    private static func backfilledKey(_ metric: NocturneSyncMetric) -> String {
        "NocturneSyncStatus.lastBackfilled.\(metric.rawValue)"
    }

    static func markSynced(_ metric: NocturneSyncMetric, at date: Date = Date()) {
        UserDefaults.standard.set(date, forKey: syncedKey(metric))
    }

    static func lastSynced(_ metric: NocturneSyncMetric) -> Date? {
        UserDefaults.standard.object(forKey: syncedKey(metric)) as? Date
    }

    static func markBackfilled(_ metric: NocturneSyncMetric, at date: Date = Date()) {
        UserDefaults.standard.set(date, forKey: backfilledKey(metric))
    }

    static func lastBackfilled(_ metric: NocturneSyncMetric) -> Date? {
        UserDefaults.standard.object(forKey: backfilledKey(metric)) as? Date
    }
}
