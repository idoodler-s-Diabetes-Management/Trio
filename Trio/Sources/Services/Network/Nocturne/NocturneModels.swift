import Foundation

// MARK: - Heart Rate

/// Body for creating/updating a heart rate reading, matching Nocturne's `UpsertHeartRateRequest`.
struct NocturneHeartRateUpload: Encodable {
    var timestamp: Date
    var utcOffset: Int?
    var bpm: Int
    var accuracy: Int
    var device: String?
    var app: String?
    var dataSource: String?
    var syncIdentifier: String?
}

/// A heart rate record as returned by the Nocturne API.
struct NocturneHeartRate: Decodable {
    var id: String?
    var timestamp: Date
    var utcOffset: Int?
    var bpm: Int
    var accuracy: Int
    var device: String?
    var enteredBy: String?
    var dataSource: String?
    var syncIdentifier: String?

    private enum CodingKeys: String, CodingKey {
        case id = "_id"
        case timestamp
        case utcOffset
        case bpm
        case accuracy
        case device
        case enteredBy
        case dataSource = "data_source"
        case syncIdentifier
    }
}

// MARK: - Step Count

/// Body for creating/updating a step count reading, matching Nocturne's `UpsertStepCountRequest`.
struct NocturneStepCountUpload: Encodable {
    var timestamp: Date
    var utcOffset: Int?
    /// The step count/movement metric for the measurement period.
    var metric: Int
    /// Source bitmask: bit 0 (value 1) means `metric` is an absolute total, otherwise a delta.
    var source: Int
    var device: String?
    var app: String?
    var dataSource: String?
    var syncIdentifier: String?
}

/// A step count record as returned by the Nocturne API.
struct NocturneStepCount: Decodable {
    var id: String?
    var timestamp: Date
    var utcOffset: Int?
    var metric: Int
    var source: Int
    var device: String?
    var enteredBy: String?
    var dataSource: String?
    var syncIdentifier: String?

    private enum CodingKeys: String, CodingKey {
        case id = "_id"
        case timestamp
        case utcOffset
        case metric
        case source
        case device
        case enteredBy
        case dataSource = "data_source"
        case syncIdentifier
    }
}

/// Bit 0 of `StepCount.source`: set when `metric` is an absolute running total rather than a delta.
enum NocturneStepCountSource {
    static let absoluteTotal = 1
    static let delta = 0
}

// MARK: - Sleep

/// Sleep stage classification within a sleep session. Raw values match Nocturne's
/// `SleepStageType` enum member names verbatim (its `JsonStringEnumConverter` serializes them
/// as-is, with no casing transform).
enum NocturneSleepStageType: String, Codable {
    case unknown = "Unknown"
    case inBed = "InBed"
    case awake = "Awake"
    case awakeInBed = "AwakeInBed"
    case outOfBed = "OutOfBed"
    case light = "Light"
    case deep = "Deep"
    case rem = "Rem"
    case asleep = "Asleep"
    case restless = "Restless"
    case unmeasurable = "Unmeasurable"
}

/// Matches Nocturne's `SleepSessionType` enum member names verbatim.
enum NocturneSleepSessionType: String, Codable {
    case overnight = "Overnight"
    case nap = "Nap"
    case rest = "Rest"
    case unknown = "Unknown"
}

/// Matches Nocturne's `SleepDetectionMethod` enum member names verbatim.
enum NocturneSleepDetectionMethod: String, Codable {
    case auto = "Auto"
    case manual = "Manual"
    case autoTentative = "AutoTentative"
    case autoFinal = "AutoFinal"
    case enhanced = "Enhanced"
    case enhancedFinal = "EnhancedFinal"
    case device = "Device"
    case unknown = "Unknown"
}

/// Matches Nocturne's `SleepSource` enum member names verbatim.
enum NocturneSleepSource: String, Codable {
    case apple = "Apple"
    case google = "Google"
    case fitbit = "Fitbit"
    case oura = "Oura"
    case garmin = "Garmin"
    case samsung = "Samsung"
    case manual = "Manual"
}

struct NocturneSleepStageInterval: Codable {
    var startTime: Date
    var endTime: Date
    var stage: NocturneSleepStageType
    var ordinal: Int
}

struct NocturneSleepBiometricSample: Codable {
    var timestamp: Date
    var heartRate: Double?
    var hrv: Double?
    var spo2: Double?
    var respirationRate: Double?
    var movement: Double?
}

/// A sleep session, matching Nocturne's `SleepSession` model. Used both as the request body for
/// create/update calls and as the decoded response — the server accepts the same shape it returns.
struct NocturneSleepSession: Codable {
    var id: String?
    var startTime: Date
    var endTime: Date
    var timezone: String?
    var type: NocturneSleepSessionType
    var detectionMethod: NocturneSleepDetectionMethod
    var isMainSleep: Bool?
    var durationMs: Int64
    var totalSleepMs: Int64
    var totalAwakeMs: Int64?
    var deepSleepMs: Int64?
    var lightSleepMs: Int64?
    var remSleepMs: Int64?
    var sleepLatencyMs: Int64?
    var efficiency: Double?
    var restlessPeriods: Int?
    var sleepScore: Int?
    var avgHeartRate: Double?
    var minHeartRate: Double?
    var avgHrv: Double?
    var avgBreathRate: Double?
    var avgSpo2: Double?
    var source: NocturneSleepSource
    var sourceDevice: String?
    var sourceApp: String?
    /// The original ID from the source system (used by the server for deduplication).
    var originalId: String?
    var stages: [NocturneSleepStageInterval]?
    var biometricSamples: [NocturneSleepBiometricSample]?
}

// MARK: - Pagination

struct NocturnePaginationInfo: Decodable {
    var limit: Int
    var offset: Int
    var total: Int
}

/// Generic paginated response wrapper used by all V4 collection endpoints.
struct NocturnePaginatedResponse<T: Decodable>: Decodable {
    var data: [T]
    var pagination: NocturnePaginationInfo
}
