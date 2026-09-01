import Combine
import Foundation
import HealthKit
import Swinject
import UIKit

protocol NocturneManager: AnyObject {
    /// Whether a Nocturne URL + credential are stored and the Nocturne integration is enabled.
    var isConfigured: Bool { get }
    /// Requests HealthKit read authorization for the metrics Nocturne can sync (steps, heart
    /// rate, sleep analysis), then (re)starts observing them for background sync.
    func requestHealthKitPermission() async throws -> Bool
    /// Whether Trio has asked the user for HealthKit read permission at least once.
    ///
    /// HealthKit deliberately never reveals whether *read* authorization for a given type was
    /// granted or denied (only share/write authorization is queryable), so this can only track
    /// whether the permission sheet has been shown — not the per-type outcome. The Settings UI
    /// uses it to decide whether to point the user at the iOS Health app to double-check access.
    var didRequestHealthKitPermission: Bool { get }
    /// Re-evaluates which metrics should be observed (call after a Settings toggle changes).
    func updateObservedMetrics()
    /// Requests an immediate sync of every enabled metric. Safe to call from anywhere; actual
    /// uploads are throttled and run on a background queue.
    func syncNow()
    /// Uploads the last 24 hours of every enabled metric from Apple Health to Nocturne, bypassing
    /// the incremental sync anchors — mirrors Nightscout's "Backfill Glucose". Useful right after
    /// connecting, so Nocturne isn't limited to data recorded from that point forward.
    func backfillHealthData() async throws
}

enum NocturneManagerError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return String(localized: "Nocturne is not connected or Health Sync is disabled")
        }
    }
}

/// Reads Steps, Heart Rate, and Sleep Analysis from Apple Health and uploads them to a
/// self-hosted or cloud Nocturne server via its v4 Health API.
///
/// Unlike ``NightscoutManager`` — which uploads data Trio itself produced (glucose, treatments,
/// device status) to Nightscout-compatible servers, including Nocturne, over the v1 API — this
/// manager is concerned only with metrics captured elsewhere on the phone. It owns its own
/// HealthKit read authorization and its own delta-sync anchors, independent of
/// ``HealthKitManager``, which only ever writes Trio's data into Apple Health.
final class BaseNocturneManager: NocturneManager, Injectable {
    @Injected() private var keychain: Keychain!
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var reachabilityManager: ReachabilityManager!
    @Injected() private var healthKitStore: HKHealthStore!

    private enum Metric: CaseIterable {
        case heartRate
        case stepCount
        case sleep

        var syncMetric: NocturneSyncMetric {
            switch self {
            case .heartRate: return .heartRate
            case .stepCount: return .steps
            case .sleep: return .sleep
            }
        }
    }

    private enum AppleHealth {
        static let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate)!
        static let stepCountType = HKObjectType.quantityType(forIdentifier: .stepCount)!
        static let sleepAnalysisType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!

        static var readTypes: Set<HKSampleType> { [heartRateType, stepCountType, sleepAnalysisType] }
    }

    /// Batch size for HeartRate/StepCount uploads. Nocturne doesn't document a hard cap for
    /// these (unlike the sleep bulk endpoint's 100), so this is a conservative, arbitrary limit
    /// to keep individual request bodies small.
    private let maxRecordsPerUpload = 200

    /// Coalesces bursts of HealthKit observer callbacks into a single sync per metric.
    private let syncThrottle: TimeInterval = 30

    /// How far back ``backfillHealthData()`` looks, matching Nightscout's fixed 24-hour backfill.
    private let backfillWindow: TimeInterval = 24 * 60 * 60

    private let processQueue = DispatchQueue(label: "BaseNocturneManager.processQueue", qos: .utility)

    private let syncSubjects: [Metric: PassthroughSubject<Void, Never>] = {
        var subjects = [Metric: PassthroughSubject<Void, Never>]()
        Metric.allCases.forEach { subjects[$0] = PassthroughSubject<Void, Never>() }
        return subjects
    }()

    private var subscriptions = Set<AnyCancellable>()
    private var observerQueries: [HKObserverQuery] = []

    private var isAvailableOnCurrentDevice: Bool { HKHealthStore.isHealthDataAvailable() }

    init(resolver: Resolver) {
        injectServices(resolver)
        setupSyncPipelines()
        updateObservedMetrics()
        observeProtectedDataAvailability()
    }

    /// HealthKit's database is inaccessible while the device is locked (`HKError.errorDatabaseInaccessible`,
    /// code 6, "Protected health data is inaccessible") — exactly the state the phone is normally in when
    /// background delivery fires. `sync(_:)` skips the query outright while locked rather than let it fail,
    /// and this retries every enabled metric the moment the device unlocks, so a sync that's been skipping
    /// all night catches up as soon as the phone is opened.
    private func observeProtectedDataAvailability() {
        Foundation.NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)
            .sink { [weak self] _ in
                self?.syncNow()
            }
            .store(in: &subscriptions)
    }

    // MARK: - Configuration

    var isConfigured: Bool { nocturneAPI != nil }

    private var nocturneAPI: NocturneAPI? {
        guard settingsManager.settings.useNocturne,
              let urlString = keychain.getValue(String.self, forKey: NocturneConfig.Config.urlKey),
              let url = URL(string: urlString),
              let secret = keychain.getValue(String.self, forKey: NocturneConfig.Config.secretKey),
              secret.isNotEmpty
        else { return nil }
        return NocturneAPI(url: url, secret: secret)
    }

    // MARK: - HealthKit permission

    private static let didRequestPermissionDefaultsKey = "BaseNocturneManager.didRequestHealthKitPermission"

    var didRequestHealthKitPermission: Bool {
        UserDefaults.standard.bool(forKey: Self.didRequestPermissionDefaultsKey)
    }

    func requestHealthKitPermission() async throws -> Bool {
        guard isAvailableOnCurrentDevice else {
            throw HKError.notAvailableOnCurrentDevice
        }

        // `status` only reflects whether the request completed, not whether any individual type
        // was granted — HealthKit never discloses read-authorization outcomes to the requester.
        let status = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Swift.Error>) in
            healthKitStore.requestAuthorization(toShare: [], read: AppleHealth.readTypes) { status, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: status)
                }
            }
        }

        UserDefaults.standard.set(true, forKey: Self.didRequestPermissionDefaultsKey)
        updateObservedMetrics()
        return status
    }

    // MARK: - HealthKit observation

    func updateObservedMetrics() {
        observerQueries.forEach { healthKitStore.stop($0) }
        observerQueries.removeAll()

        guard isAvailableOnCurrentDevice, settingsManager.settings.useNocturne else { return }

        if settingsManager.settings.nocturneSyncHeartRate {
            observe(type: AppleHealth.heartRateType, metric: .heartRate)
        }
        if settingsManager.settings.nocturneSyncSteps {
            observe(type: AppleHealth.stepCountType, metric: .stepCount)
        }
        if settingsManager.settings.nocturneSyncSleep {
            observe(type: AppleHealth.sleepAnalysisType, metric: .sleep)
        }
    }

    private func observe(type: HKSampleType, metric: Metric) {
        // Read authorization status for `type` isn't queryable (HealthKit only exposes
        // share/write status), so this is registered unconditionally once Nocturne + this metric
        // are enabled. If the user denied read access, HealthKit simply never calls back with
        // data — there's no error to guard against here.
        let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completionHandler, error in
            defer { completionHandler() }
            guard error == nil else { return }
            self?.requestSync(metric)
        }
        healthKitStore.execute(query)
        healthKitStore.enableBackgroundDelivery(for: type, frequency: .hourly) { _, _ in }
        observerQueries.append(query)

        // Pick up anything written while Trio wasn't running.
        requestSync(metric)
    }

    // MARK: - Sync pipeline

    private func setupSyncPipelines() {
        for metric in Metric.allCases {
            syncSubjects[metric]?
                .receive(on: processQueue)
                .throttle(for: .seconds(syncThrottle), scheduler: processQueue, latest: true)
                .sink { [weak self] in
                    guard let self else { return }
                    Task(priority: .utility) { await self.sync(metric) }
                }
                .store(in: &subscriptions)
        }
    }

    private func requestSync(_ metric: Metric) {
        syncSubjects[metric]?.send(())
    }

    func syncNow() {
        Metric.allCases.forEach(requestSync)
    }

    private func sync(_ metric: Metric) async {
        guard reachabilityManager.isReachable, let api = nocturneAPI else { return }

        // Querying HealthKit while the device is locked reliably fails with
        // HKError.errorDatabaseInaccessible. Skip quietly instead of attempting a doomed query —
        // observeProtectedDataAvailability() retries as soon as the device unlocks. Recorded so
        // the settings screen can tell the user why a sync is pending instead of looking broken.
        guard await UIApplication.shared.isProtectedDataAvailable else {
            NocturneSyncStatus.markSkippedLocked(metric.syncMetric)
            return
        }

        switch metric {
        case .heartRate:
            guard settingsManager.settings.nocturneSyncHeartRate else { return }
            await syncHeartRate(api: api)
        case .stepCount:
            guard settingsManager.settings.nocturneSyncSteps else { return }
            await syncStepCount(api: api)
        case .sleep:
            guard settingsManager.settings.nocturneSyncSleep else { return }
            await syncSleep(api: api)
        }
    }

    private func syncHeartRate(api: NocturneAPI) async {
        do {
            let uploaded = try await syncPaged(
                type: AppleHealth.heartRateType,
                upload: { (samples: [HKQuantitySample]) in try await self.uploadHeartRateSamples(samples, api: api) }
            )
            NocturneSyncStatus.markSynced(.heartRate)
            debug(.nocturne, "Heart rate uploaded (\(uploaded) samples)")
        } catch {
            warning(.nocturne, "Failed to sync heart rate to Nocturne", error: error)
        }
    }

    private func syncStepCount(api: NocturneAPI) async {
        do {
            let uploaded = try await syncPaged(
                type: AppleHealth.stepCountType,
                upload: { (samples: [HKQuantitySample]) in try await self.uploadStepCountSamples(samples, api: api) }
            )
            NocturneSyncStatus.markSynced(.steps)
            debug(.nocturne, "Step count uploaded (\(uploaded) samples)")
        } catch {
            warning(.nocturne, "Failed to sync step count to Nocturne", error: error)
        }
    }

    /// Fetches and uploads new samples of `type` one HealthKit anchor-page at a time (page size
    /// `maxRecordsPerUpload`), saving the anchor after each page succeeds rather than only once
    /// the whole backlog is uploaded.
    ///
    /// Heart rate and step count can accumulate thousands of small delta samples between synced
    /// devices; fetching them in one unbounded batch made the whole sync all-or-nothing — a single
    /// dropped connection partway through a large backlog meant the anchor never advanced and the
    /// next attempt had to resend everything (plus whatever had accumulated since), so a server
    /// hiccup during a large backlog could permanently stall this metric. Paging makes each
    /// successful page a durable checkpoint, so a later failure only has to retry from there.
    private func syncPaged<T: HKSample>(
        type: HKSampleType,
        upload: (_ samples: [T]) async throws -> Void
    ) async throws -> Int {
        var totalUploaded = 0
        while true {
            let (samples, newAnchor): ([T], HKQueryAnchor?) = try await fetchNewSamples(
                type: type,
                limit: maxRecordsPerUpload
            )
            guard samples.isNotEmpty else { break }
            try await upload(samples)
            totalUploaded += samples.count
            // A nil anchor here would mean no further progress can be checkpointed; stop rather
            // than risk looping forever re-fetching the same page. Re-uploading is idempotent
            // server-side (matched by `syncIdentifier`), so this can only cost efficiency, not data.
            guard let newAnchor else { break }
            saveAnchor(newAnchor, for: type)
            if samples.count < maxRecordsPerUpload { break }
        }
        return totalUploaded
    }

    private func syncSleep(api: NocturneAPI) async {
        do {
            let (samples, newAnchor): ([HKCategorySample], HKQueryAnchor?) =
                try await fetchNewSamples(type: AppleHealth.sleepAnalysisType)
            try await uploadSleepSamples(samples, api: api)
            saveAnchor(newAnchor, for: AppleHealth.sleepAnalysisType)
            NocturneSyncStatus.markSynced(.sleep)
            debug(.nocturne, "Sleep sessions uploaded (\(samples.count) samples)")
        } catch {
            warning(.nocturne, "Failed to sync sleep sessions to Nocturne", error: error)
        }
    }

    // MARK: - Backfill

    /// Uploads the last 24 hours of every enabled metric, independent of the sync anchors.
    /// Unlike the anchored sync, a sample already picked up by the incremental sync (or a
    /// previous backfill) is uploaded again here — `syncIdentifier`/`originalId` make that an
    /// idempotent upsert server-side rather than a duplicate.
    func backfillHealthData() async throws {
        guard reachabilityManager.isReachable, let api = nocturneAPI else {
            throw NocturneManagerError.notConfigured
        }

        let since = Date().addingTimeInterval(-backfillWindow)

        if settingsManager.settings.nocturneSyncHeartRate {
            let samples: [HKQuantitySample] = try await fetchSamples(type: AppleHealth.heartRateType, since: since)
            try await uploadHeartRateSamples(samples, api: api)
            NocturneSyncStatus.markBackfilled(.heartRate)
        }
        if settingsManager.settings.nocturneSyncSteps {
            let samples: [HKQuantitySample] = try await fetchSamples(type: AppleHealth.stepCountType, since: since)
            try await uploadStepCountSamples(samples, api: api)
            NocturneSyncStatus.markBackfilled(.steps)
        }
        if settingsManager.settings.nocturneSyncSleep {
            let samples: [HKCategorySample] = try await fetchSamples(type: AppleHealth.sleepAnalysisType, since: since)
            try await uploadSleepSamples(samples, api: api)
            NocturneSyncStatus.markBackfilled(.sleep)
        }
    }

    // MARK: - Sample -> upload mapping

    private func uploadHeartRateSamples(_ samples: [HKQuantitySample], api: NocturneAPI) async throws {
        guard samples.isNotEmpty else { return }

        let bpmUnit = HKUnit.count().unitDivided(by: .minute())
        let uploads = samples.map { sample in
            NocturneHeartRateUpload(
                timestamp: sample.startDate,
                utcOffset: utcOffsetMinutes(at: sample.startDate),
                bpm: Int(sample.quantity.doubleValue(for: bpmUnit).rounded()),
                accuracy: 0,
                device: sample.device?.name,
                app: sample.sourceRevision.source.name,
                dataSource: "AppleHealth",
                syncIdentifier: sample.uuid.uuidString
            )
        }

        for batch in uploads.chunked(into: maxRecordsPerUpload) {
            try await api.uploadHeartRates(batch)
        }
    }

    private func uploadStepCountSamples(_ samples: [HKQuantitySample], api: NocturneAPI) async throws {
        guard samples.isNotEmpty else { return }

        let uploads = samples.map { sample in
            NocturneStepCountUpload(
                timestamp: sample.startDate,
                utcOffset: utcOffsetMinutes(at: sample.startDate),
                // A HealthKit step-count sample is a delta over [startDate, endDate).
                metric: Int(sample.quantity.doubleValue(for: .count()).rounded()),
                source: NocturneStepCountSource.delta,
                device: sample.device?.name,
                app: sample.sourceRevision.source.name,
                dataSource: "AppleHealth",
                syncIdentifier: sample.uuid.uuidString
            )
        }

        for batch in uploads.chunked(into: maxRecordsPerUpload) {
            try await api.uploadStepCounts(batch)
        }
    }

    private func uploadSleepSamples(_ samples: [HKCategorySample], api: NocturneAPI) async throws {
        guard samples.isNotEmpty else { return }

        let sessions = NocturneSleepSessionMapper.makeSessions(from: samples)
        guard sessions.isNotEmpty else { return }

        try await api.createSleepSessionsBulk(sessions)
    }

    private func utcOffsetMinutes(at date: Date) -> Int {
        TimeZone.current.secondsFromGMT(for: date) / 60
    }

    // MARK: - Anchored delta sync

    private func fetchNewSamples<T: HKSample>(
        type: HKSampleType,
        limit: Int = HKObjectQueryNoLimit
    ) async throws -> (samples: [T], anchor: HKQueryAnchor?) {
        let previousAnchor = loadAnchor(for: type)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: type,
                predicate: nil,
                anchor: previousAnchor,
                limit: limit
            ) { _, samplesOrNil, _, newAnchor, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: ((samplesOrNil as? [T]) ?? [], newAnchor))
            }
            healthKitStore.execute(query)
        }
    }

    /// Plain (non-anchored) fetch of every sample of `type` since `since`, used by
    /// ``backfillHealthData()``. Unlike ``fetchNewSamples(type:)`` this doesn't consume or
    /// advance the sync anchor, so it can freely re-fetch a window the anchored sync already
    /// covered.
    private func fetchSamples<T: HKSample>(type: HKSampleType, since: Date) async throws -> [T] {
        let predicate = HKQuery.predicateForSamples(withStart: since, end: nil, options: .strictStartDate)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samplesOrNil, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (samplesOrNil as? [T]) ?? [])
            }
            healthKitStore.execute(query)
        }
    }

    private func anchorDefaultsKey(for type: HKSampleType) -> String {
        "BaseNocturneManager.anchor.\(type.identifier)"
    }

    private func loadAnchor(for type: HKSampleType) -> HKQueryAnchor? {
        guard let data = UserDefaults.standard.data(forKey: anchorDefaultsKey(for: type)) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    private func saveAnchor(_ anchor: HKQueryAnchor?, for type: HKSampleType) {
        guard let anchor,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
        else { return }
        UserDefaults.standard.set(data, forKey: anchorDefaultsKey(for: type))
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0 ..< Swift.min($0 + size, count)]) }
    }
}
