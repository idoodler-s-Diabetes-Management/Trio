import Foundation
import HealthKit

/// Groups discrete `HKCategoryValueSleepAnalysis` samples — Apple Health records one sample per
/// contiguous stage interval, not one per night — into `NocturneSleepSession`s the way a sleep
/// session actually reads: contiguous stage intervals from the same source, separated by no more
/// than `sessionGapThreshold`, belong to one session (one night, or one nap).
enum NocturneSleepSessionMapper {
    /// Two stage intervals farther apart than this belong to different sessions (e.g. a nap and
    /// the following night's sleep, or two unrelated naps).
    private static let sessionGapThreshold: TimeInterval = 60 * 60

    /// A session shorter than this isn't a meaningful sleep/nap session on its own.
    private static let minimumSessionDuration: TimeInterval = 5 * 60

    /// A session at least this long, starting in the evening/night, is treated as the primary
    /// overnight sleep rather than a nap.
    private static let minimumOvernightDuration: TimeInterval = 3 * 60 * 60

    /// Builds one `NocturneSleepSession` per cluster of same-source, closely-spaced samples.
    ///
    /// Note: because this only sees whatever samples HealthKit's anchored query hands it, a
    /// session whose stage intervals are written to Apple Health across two separate sync
    /// windows will be uploaded as two sessions rather than merged into one. In practice, sleep
    /// tracking sources (Apple Watch, most sleep apps) commit a full night's stage data in one
    /// batch on wake, so this is rare.
    static func makeSessions(from samples: [HKCategorySample]) -> [NocturneSleepSession] {
        let sorted = samples.sorted { $0.startDate < $1.startDate }

        var clusters: [[HKCategorySample]] = []
        for sample in sorted {
            if let lastSample = clusters.last?.last,
               sample.sourceRevision.source.bundleIdentifier == lastSample.sourceRevision.source.bundleIdentifier,
               sample.startDate.timeIntervalSince(lastSample.endDate) <= sessionGapThreshold
            {
                clusters[clusters.count - 1].append(sample)
            } else {
                clusters.append([sample])
            }
        }

        return clusters.compactMap(makeSession(from:))
    }

    private static func makeSession(from samples: [HKCategorySample]) -> NocturneSleepSession? {
        guard let firstSample = samples.first,
              let sessionStart = samples.map(\.startDate).min(),
              let sessionEnd = samples.map(\.endDate).max()
        else { return nil }

        let duration = sessionEnd.timeIntervalSince(sessionStart)
        guard duration >= minimumSessionDuration else { return nil }

        var stages: [NocturneSleepStageInterval] = []
        stages.reserveCapacity(samples.count)

        var totalSleep: TimeInterval = 0
        var totalAwake: TimeInterval = 0
        var deepSleep: TimeInterval = 0
        var lightSleep: TimeInterval = 0
        var remSleep: TimeInterval = 0

        for (index, sample) in samples.enumerated() {
            let stage = stageType(for: sample)
            let intervalDuration = sample.endDate.timeIntervalSince(sample.startDate)

            switch stage {
            case .light:
                totalSleep += intervalDuration
                lightSleep += intervalDuration
            case .deep:
                totalSleep += intervalDuration
                deepSleep += intervalDuration
            case .rem:
                totalSleep += intervalDuration
                remSleep += intervalDuration
            case .asleep:
                totalSleep += intervalDuration
            case .awake, .awakeInBed:
                totalAwake += intervalDuration
            case .inBed, .outOfBed, .restless, .unmeasurable, .unknown:
                break
            }

            stages.append(NocturneSleepStageInterval(
                startTime: sample.startDate,
                endTime: sample.endDate,
                stage: stage,
                ordinal: index
            ))
        }

        let hasStageDetail = stages.contains { $0.stage == .light || $0.stage == .deep || $0.stage == .rem }
        let startHour = Calendar.current.component(.hour, from: sessionStart)
        let isOvernightWindow = startHour >= 18 || startHour < 10
        let isMainSleep = duration >= minimumOvernightDuration && isOvernightWindow

        let sourceBundleID = firstSample.sourceRevision.source.bundleIdentifier
        let originalId = "apple-\(sourceBundleID)-\(Int(sessionStart.timeIntervalSince1970))"

        return NocturneSleepSession(
            id: nil,
            startTime: sessionStart,
            endTime: sessionEnd,
            timezone: TimeZone.current.identifier,
            type: isMainSleep ? .overnight : .nap,
            detectionMethod: .auto,
            isMainSleep: isMainSleep,
            durationMs: Int64(duration * 1000),
            totalSleepMs: Int64(totalSleep * 1000),
            totalAwakeMs: Int64(totalAwake * 1000),
            deepSleepMs: hasStageDetail ? Int64(deepSleep * 1000) : nil,
            lightSleepMs: hasStageDetail ? Int64(lightSleep * 1000) : nil,
            remSleepMs: hasStageDetail ? Int64(remSleep * 1000) : nil,
            sleepLatencyMs: nil,
            efficiency: duration > 0 ? totalSleep / duration * 100 : nil,
            restlessPeriods: nil,
            sleepScore: nil,
            avgHeartRate: nil,
            minHeartRate: nil,
            avgHrv: nil,
            avgBreathRate: nil,
            avgSpo2: nil,
            source: .apple,
            sourceDevice: firstSample.device?.name,
            sourceApp: firstSample.sourceRevision.source.name,
            originalId: originalId,
            stages: stages,
            biometricSamples: nil
        )
    }

    private static func stageType(for sample: HKCategorySample) -> NocturneSleepStageType {
        guard let value = HKCategoryValueSleepAnalysis(rawValue: sample.value) else { return .unknown }
        switch value {
        case .inBed: return .inBed
        case .awake: return .awake
        case .asleepUnspecified: return .asleep
        case .asleepCore: return .light
        case .asleepDeep: return .deep
        case .asleepREM: return .rem
        @unknown default: return .unknown
        }
    }
}
