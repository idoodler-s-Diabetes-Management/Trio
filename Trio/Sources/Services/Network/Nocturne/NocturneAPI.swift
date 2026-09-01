import CommonCrypto
import Foundation

/// Low-level HTTP client for the Nocturne API (https://getnocturne.dev).
///
/// Nocturne mirrors the Nightscout v1 API 1:1 and additionally exposes a v4 API for data
/// Nightscout has no equivalent for. This client covers both surfaces:
/// - v1-compatible endpoints (glucose entries, treatments, device status, profile) — the same
///   data Trio already sends to Nightscout, reusing the exact same Codable types, so Nocturne can
///   fully stand in for a Nightscout connection.
/// - v4 Health endpoints (HeartRate, StepCount, Sleep sessions) — per-user health metrics
///   captured on the phone rather than produced by the loop itself, typically sourced from
///   Apple Health, which Nightscout has no representation for at all.
///
/// Authentication mirrors ``NightscoutAPI``: Nocturne accepts a Nightscout-compatible API
/// secret (SHA-1 hashed, sent as `api-secret`) as well as a Nocturne direct grant token
/// (prefixed `noc_`, sent as a bearer token). Both are supported here so a single "API secret /
/// token" field works with either a Nightscout-style secret or a Nocturne-issued token.
final class NocturneAPI {
    init(url: URL, secret: String? = nil) {
        self.url = url
        self.secret = secret?.nonEmpty
    }

    private enum Config {
        static let entriesPath = "/api/v1/entries.json"
        static let treatmentsPath = "/api/v1/treatments.json"
        static let statusPath = "/api/v1/devicestatus.json"
        static let profilePath = "/api/v1/profile.json"
        static let heartRatePath = "/api/v4/HeartRate"
        static let stepCountPath = "/api/v4/StepCount"
        static let sleepSessionsPath = "/api/v4/sleep/sessions"
        static let timeout: TimeInterval = 60
        /// Matches the server's `SleepController.CreateSessionsBulk` cap.
        static let maxSleepSessionsPerBulkRequest = 100
    }

    enum NocturneAPIError: LocalizedError {
        case invalidURL
        case badStatusCode(Int)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return String(localized: "Invalid Nocturne server URL")
            case let .badStatusCode(code):
                return String(localized: "Nocturne server returned HTTP \(code)")
            }
        }
    }

    let url: URL
    let secret: String?

    private func authenticate(_ request: inout URLRequest) {
        guard let secret else { return }
        if secret.hasPrefix("noc_") {
            request.addValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        } else {
            request.addValue(secret.sha1(), forHTTPHeaderField: "api-secret")
        }
    }

    private func makeRequest(path: String, method: String, queryItems: [URLQueryItem]? = nil) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        components.path = path
        components.queryItems = queryItems

        guard let requestURL = components.url else {
            throw NocturneAPIError.invalidURL
        }

        var request = URLRequest(url: requestURL)
        request.allowsConstrainedNetworkAccess = false
        request.timeoutInterval = Config.timeout
        request.httpMethod = method
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        authenticate(&request)
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200 ..< 300).contains(httpResponse.statusCode) else {
            throw NocturneAPIError.badStatusCode((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }

    private func send(_ request: URLRequest, body: some Encodable) async throws -> Data {
        var request = request
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONCoding.encoder.encode(body)
        return try await send(request)
    }

    private static func dateQueryItem(_ name: String, _ date: Date) -> URLQueryItem {
        URLQueryItem(name: name, value: Formatter.iso8601withFractionalSeconds.string(from: date))
    }
}

// MARK: - Connection check

extension NocturneAPI {
    /// Verifies the URL is reachable and the credential is valid by requesting a single heart
    /// rate record — the same `heartrate.read` scope every health upload in this client needs.
    func checkConnection() async throws {
        let request = try makeRequest(
            path: Config.heartRatePath,
            method: "GET",
            queryItems: [URLQueryItem(name: "count", value: "1")]
        )
        _ = try await send(request)
    }
}

// MARK: - Nightscout-compatible uploads (/api/v1/*)

extension NocturneAPI {
    /// Uploads glucose entries, identical to `NightscoutAPI.uploadGlucose(_:)`.
    func uploadGlucose(_ glucose: [BloodGlucose]) async throws {
        let request = try makeRequest(path: Config.entriesPath, method: "POST")
        _ = try await send(request, body: glucose)
    }

    /// Uploads treatments (carbs, boluses, temp basals, temp targets), identical to
    /// `NightscoutAPI.uploadTreatments(_:)`.
    func uploadTreatments(_ treatments: [NightscoutTreatment]) async throws {
        let request = try makeRequest(path: Config.treatmentsPath, method: "POST")
        _ = try await send(request, body: treatments)
    }

    /// Uploads overrides, which Nightscout (and Nocturne) represent as treatments under a
    /// different payload shape. Identical to `NightscoutAPI.uploadOverrides(_:)`.
    func uploadOverrides(_ overrides: [NightscoutExercise]) async throws {
        let request = try makeRequest(path: Config.treatmentsPath, method: "POST")
        _ = try await send(request, body: overrides)
    }

    /// Uploads the OpenAPS/pump device status snapshot, identical to
    /// `NightscoutAPI.uploadDeviceStatus(_:)`.
    func uploadDeviceStatus(_ status: NightscoutStatus) async throws {
        let request = try makeRequest(path: Config.statusPath, method: "POST")
        _ = try await send(request, body: status)
    }

    /// Uploads the therapy settings profile, identical to `NightscoutAPI.uploadProfile(_:)`.
    func uploadProfile(_ profile: NightscoutProfileStore) async throws {
        let request = try makeRequest(path: Config.profilePath, method: "POST")
        _ = try await send(request, body: profile)
    }
}

// MARK: - Heart Rate (/api/v4/HeartRate)

extension NocturneAPI {
    func fetchHeartRates(count: Int = 10, skip: Int = 0, from: Date? = nil, to: Date? = nil) async throws -> [NocturneHeartRate] {
        var items = [URLQueryItem(name: "count", value: String(count)), URLQueryItem(name: "skip", value: String(skip))]
        if let from { items.append(Self.dateQueryItem("from", from)) }
        if let to { items.append(Self.dateQueryItem("to", to)) }

        let request = try makeRequest(path: Config.heartRatePath, method: "GET", queryItems: items)
        let data = try await send(request)
        return try JSONCoding.decoder.decode([NocturneHeartRate].self, from: data)
    }

    @discardableResult func uploadHeartRates(_ heartRates: [NocturneHeartRateUpload]) async throws -> [NocturneHeartRate] {
        guard heartRates.isNotEmpty else { return [] }
        let request = try makeRequest(path: Config.heartRatePath, method: "POST")
        let data = try await send(request, body: heartRates)
        return try JSONCoding.decoder.decode([NocturneHeartRate].self, from: data)
    }

    @discardableResult func updateHeartRate(id: String, _ heartRate: NocturneHeartRateUpload) async throws -> NocturneHeartRate {
        let request = try makeRequest(path: "\(Config.heartRatePath)/\(id)", method: "PUT")
        let data = try await send(request, body: heartRate)
        return try JSONCoding.decoder.decode(NocturneHeartRate.self, from: data)
    }

    func deleteHeartRate(id: String) async throws {
        let request = try makeRequest(path: "\(Config.heartRatePath)/\(id)", method: "DELETE")
        _ = try await send(request)
    }
}

// MARK: - Step Count (/api/v4/StepCount)

extension NocturneAPI {
    func fetchStepCounts(count: Int = 10, skip: Int = 0, from: Date? = nil, to: Date? = nil) async throws -> [NocturneStepCount] {
        var items = [URLQueryItem(name: "count", value: String(count)), URLQueryItem(name: "skip", value: String(skip))]
        if let from { items.append(Self.dateQueryItem("from", from)) }
        if let to { items.append(Self.dateQueryItem("to", to)) }

        let request = try makeRequest(path: Config.stepCountPath, method: "GET", queryItems: items)
        let data = try await send(request)
        return try JSONCoding.decoder.decode([NocturneStepCount].self, from: data)
    }

    @discardableResult func uploadStepCounts(_ stepCounts: [NocturneStepCountUpload]) async throws -> [NocturneStepCount] {
        guard stepCounts.isNotEmpty else { return [] }
        let request = try makeRequest(path: Config.stepCountPath, method: "POST")
        let data = try await send(request, body: stepCounts)
        return try JSONCoding.decoder.decode([NocturneStepCount].self, from: data)
    }

    @discardableResult func updateStepCount(id: String, _ stepCount: NocturneStepCountUpload) async throws -> NocturneStepCount {
        let request = try makeRequest(path: "\(Config.stepCountPath)/\(id)", method: "PUT")
        let data = try await send(request, body: stepCount)
        return try JSONCoding.decoder.decode(NocturneStepCount.self, from: data)
    }

    func deleteStepCount(id: String) async throws {
        let request = try makeRequest(path: "\(Config.stepCountPath)/\(id)", method: "DELETE")
        _ = try await send(request)
    }
}

// MARK: - Sleep sessions (/api/v4/sleep/sessions)

extension NocturneAPI {
    func fetchSleepSessions(
        from: Date? = nil,
        to: Date? = nil,
        limit: Int = 100,
        offset: Int = 0,
        sortDescending: Bool = true
    ) async throws -> NocturnePaginatedResponse<NocturneSleepSession> {
        var items = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "sort", value: sortDescending ? "timestamp_desc" : "timestamp_asc")
        ]
        if let from { items.append(Self.dateQueryItem("from", from)) }
        if let to { items.append(Self.dateQueryItem("to", to)) }

        let request = try makeRequest(path: Config.sleepSessionsPath, method: "GET", queryItems: items)
        let data = try await send(request)
        return try JSONCoding.decoder.decode(NocturnePaginatedResponse<NocturneSleepSession>.self, from: data)
    }

    @discardableResult func createSleepSession(_ session: NocturneSleepSession) async throws -> NocturneSleepSession {
        let request = try makeRequest(path: Config.sleepSessionsPath, method: "POST")
        let data = try await send(request, body: session)
        return try JSONCoding.decoder.decode(NocturneSleepSession.self, from: data)
    }

    /// Upserts sessions in chunks of at most 100 (the server's per-request cap).
    @discardableResult func createSleepSessionsBulk(_ sessions: [NocturneSleepSession]) async throws -> [NocturneSleepSession] {
        guard sessions.isNotEmpty else { return [] }

        var results: [NocturneSleepSession] = []
        for chunk in stride(from: 0, to: sessions.count, by: Config.maxSleepSessionsPerBulkRequest) {
            let batch = Array(sessions[chunk ..< min(chunk + Config.maxSleepSessionsPerBulkRequest, sessions.count)])
            let request = try makeRequest(path: "\(Config.sleepSessionsPath)/bulk", method: "POST")
            let data = try await send(request, body: batch)
            results.append(contentsOf: try JSONCoding.decoder.decode([NocturneSleepSession].self, from: data))
        }
        return results
    }

    @discardableResult func updateSleepSession(id: String, _ session: NocturneSleepSession) async throws -> NocturneSleepSession {
        let request = try makeRequest(path: "\(Config.sleepSessionsPath)/\(id)", method: "PUT")
        let data = try await send(request, body: session)
        return try JSONCoding.decoder.decode(NocturneSleepSession.self, from: data)
    }

    func deleteSleepSession(id: String) async throws {
        let request = try makeRequest(path: "\(Config.sleepSessionsPath)/\(id)", method: "DELETE")
        _ = try await send(request)
    }
}

private extension String {
    func sha1() -> String {
        let data = Data(utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }
}
