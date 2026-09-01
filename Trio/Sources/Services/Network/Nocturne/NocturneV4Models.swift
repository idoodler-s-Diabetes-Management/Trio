import Foundation

// MARK: - Sensor Glucose (/api/v4/glucose/sensor)

/// Matches Nocturne's `GlucoseDirection` enum member names verbatim (no casing transform).
/// A subset of `BloodGlucose.Direction`: no triple arrows, no CGM-error value.
enum NocturneGlucoseDirection: String, Encodable {
    case none = "None"
    case doubleUp = "DoubleUp"
    case singleUp = "SingleUp"
    case fortyFiveUp = "FortyFiveUp"
    case flat = "Flat"
    case fortyFiveDown = "FortyFiveDown"
    case singleDown = "SingleDown"
    case doubleDown = "DoubleDown"
    case notComputable = "NotComputable"
    case rateOutOfRange = "RateOutOfRange"
}

extension BloodGlucose.Direction {
    /// The closest `NocturneGlucoseDirection`. Triple arrows collapse to double arrows, the
    /// nearest value the native enum has.
    var nocturneDirection: NocturneGlucoseDirection {
        switch self {
        case .tripleUp, .doubleUp: return .doubleUp
        case .singleUp: return .singleUp
        case .fortyFiveUp: return .fortyFiveUp
        case .flat: return .flat
        case .fortyFiveDown: return .fortyFiveDown
        case .singleDown: return .singleDown
        case .tripleDown, .doubleDown: return .doubleDown
        case .none: return .none
        case .notComputable: return .notComputable
        case .rateOutOfRange: return .rateOutOfRange
        }
    }
}

/// Body for `POST /api/v4/glucose/sensor/bulk`, matching Nocturne's `UpsertSensorGlucoseRequest`.
///
/// Note: unlike every other V4 upload type here, this request has no `syncIdentifier` field, so
/// re-uploading the same reading creates a duplicate rather than upserting in place. In practice
/// this is harmless: `BaseNightscoutManager` only uploads each glucose reading once its
/// `isUploadedToNS` flag flips, so a retry only happens in the narrow window between a successful
/// upload and that flag being persisted.
struct NocturneSensorGlucoseUpload: Encodable {
    var timestamp: Date
    var utcOffset: Int?
    var device: String?
    var app: String?
    var dataSource: String?
    var mgdl: Double
    var direction: NocturneGlucoseDirection?
    var noise: Int?
    var filtered: Double?
    var unfiltered: Double?
}

// MARK: - Carb Intake (/api/v4/nutrition/carbs)

/// Body for `POST /api/v4/nutrition/carbs/bulk`, matching Nocturne's `CreateCarbIntakeRequest`.
///
/// `fatGrams`/`proteinGrams` are native fields Nocturne uses to model delayed glucose impact
/// itself — unlike the legacy Nightscout path, no synthetic "fake carb" FPU series is needed
/// alongside this.
struct NocturneCarbIntakeUpload: Encodable {
    var timestamp: Date
    var utcOffset: Int?
    var device: String?
    var app: String?
    var dataSource: String?
    var carbs: Double
    var syncIdentifier: String?
    var fatGrams: Double?
    var proteinGrams: Double?
}

// MARK: - Bolus (/api/v4/insulin/boluses)

/// Matches Nocturne's `BolusType` enum member names verbatim.
enum NocturneBolusType: String, Encodable {
    case normal = "Normal"
    case square = "Square"
    case dual = "Dual"
}

/// Matches Nocturne's `BolusKind` enum member names verbatim.
enum NocturneBolusKind: String, Encodable {
    case manual = "Manual"
    case algorithm = "Algorithm"
}

/// Body for `POST /api/v4/insulin/boluses/bulk`, matching Nocturne's `CreateBolusRequest`.
struct NocturneBolusUpload: Encodable {
    var timestamp: Date
    var utcOffset: Int?
    var device: String?
    var app: String?
    var dataSource: String?
    var insulin: Double
    var bolusType: NocturneBolusType?
    /// Omit for a manual dose — the server defaults `kind` to `Manual` when absent.
    var kind: NocturneBolusKind?
    var automatic: Bool
    var syncIdentifier: String?
}

// MARK: - Temp Basal (/api/v4/insulin/temp-basals)

/// Matches Nocturne's `TempBasalOrigin` enum. Unlike the other V4 enums in this file,
/// `TempBasalOrigin` carries no `JsonStringEnumConverter` server-side, so it serializes as a
/// plain integer (its C# declaration order): Algorithm=0, Scheduled=1, Manual=2, Suspended=3,
/// Inferred=4.
enum NocturneTempBasalOrigin: Int, Encodable {
    case algorithm = 0
    case scheduled = 1
    case manual = 2
    case suspended = 3
    case inferred = 4
}

/// Body for `POST /api/v4/insulin/temp-basals`, matching Nocturne's `CreateTempBasalRequest`.
/// This single endpoint is bulk by default (an array body) and doubles as the cancel endpoint:
/// a `isCancel` entry truncates whatever temp basal is active at `timestamp` instead of creating
/// a new span.
struct NocturneTempBasalUpload: Encodable {
    var timestamp: Date
    var utcOffset: Int?
    var device: String?
    var app: String?
    var dataSource: String?
    var syncIdentifier: String?
    var rate: Double
    var durationMinutes: Double?
    var scheduledRate: Double?
    var origin: NocturneTempBasalOrigin?
    var isCancel: Bool
}

// MARK: - Device status snapshots (/api/v4/device-status/*)
//
// The legacy v1 devicestatus.json payload (a single combined `openaps`/`pump`/`uploader`
// object) is decomposed server-side into exactly these three record types anyway, sharing one
// `correlationId`. Uploading them directly saves that decompose step and is the path Nocturne's
// own docs point native uploaders (Trio explicitly named) at.

/// Matches Nocturne's `AidAlgorithm` enum member names verbatim.
enum NocturneAidAlgorithm: String, Encodable {
    case openAps = "OpenAps"
    case androidAps = "AndroidAps"
    case loop = "Loop"
    case trio = "Trio"
    case iaps = "IAPS"
    case controlIQ = "ControlIQ"
    case camAPSFX = "CamAPSFX"
    case omnipod5Algorithm = "Omnipod5Algorithm"
    case medtronicSmartGuard = "MedtronicSmartGuard"
    case none = "None"
    case unknown = "Unknown"
}

/// Body for `POST /api/v4/device-status/aps`, matching Nocturne's `UpsertApsSnapshotRequest`.
///
/// Scope cut: the JSON-blob round-trip fields (`suggestedJson`, `enactedJson`, the prediction
/// curves, `loopJson`) are intentionally left unset here. They're supplementary/debugging data;
/// the numeric fields below are what drives Nocturne's own status display and alerts.
struct NocturneApsSnapshotUpload: Encodable {
    var timestamp: Date
    var utcOffset: Int?
    var device: String?
    var app: String?
    var dataSource: String?
    var syncIdentifier: String?
    var correlationId: String?
    var aidAlgorithm: NocturneAidAlgorithm
    var aidVersion: String?
    var iob: Double?
    var cob: Double?
    var currentBg: Double?
    var eventualBg: Double?
    var targetBg: Double?
    var recommendedBolus: Double?
    var sensitivityRatio: Double?
    var enacted: Bool
    var enactedRate: Double?
    var enactedDuration: Int?
}

/// Body for `POST /api/v4/device-status/pump`, matching Nocturne's `UpsertPumpSnapshotRequest`.
struct NocturnePumpSnapshotUpload: Encodable {
    var timestamp: Date
    var utcOffset: Int?
    var device: String?
    var app: String?
    var dataSource: String?
    var syncIdentifier: String?
    var correlationId: String?
    var reservoir: Double?
    var batteryPercent: Int?
    var batteryVoltage: Double?
    var bolusing: Bool?
    var suspended: Bool?
    var pumpStatus: String?
    var clock: String?
}

/// Body for `POST /api/v4/device-status/uploader`, matching Nocturne's
/// `UpsertUploaderSnapshotRequest`.
struct NocturneUploaderSnapshotUpload: Encodable {
    var timestamp: Date
    var utcOffset: Int?
    var device: String?
    var app: String?
    var dataSource: String?
    var syncIdentifier: String?
    var correlationId: String?
    var battery: Int?
    var isCharging: Bool?
    var type: String?
}
