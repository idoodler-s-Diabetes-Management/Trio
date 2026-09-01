import Combine
import SwiftUI

extension NocturneConfig {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() private var keychain: Keychain!
        @Injected() private var nocturneManager: NocturneManager!

        @Published var url = ""
        @Published var secret = ""
        @Published var message = ""
        @Published var isValidURL: Bool = true
        @Published var connecting = false
        @Published var isConnected: Bool = false
        @Published var backfilling = false

        @Published var useNocturne = false
        @Published var syncHeartRate = true
        @Published var syncSteps = true
        @Published var syncSleep = true
        @Published var uploadNightscoutData = false
        @Published var needsHealthKitPermission = false

        /// Bumped every 30s purely to force the "X ago" sync-status labels to redraw; the
        /// timestamps themselves live in ``NocturneSyncStatus`` (UserDefaults), not here.
        @Published private var statusTick = Date()

        override func subscribe() {
            url = keychain.getValue(String.self, forKey: Config.urlKey) ?? ""
            secret = keychain.getValue(String.self, forKey: Config.secretKey) ?? ""
            isConnected = url.isNotEmpty

            needsHealthKitPermission = !nocturneManager.didRequestHealthKitPermission

            subscribeSetting(\.useNocturne, on: $useNocturne) { useNocturne = $0 } didSet: { [weak self] enabled in
                guard let self else { return }
                self.nocturneManager.updateObservedMetrics()

                guard enabled else { return }
                Task {
                    _ = try? await self.nocturneManager.requestHealthKitPermission()
                    await MainActor.run {
                        self.needsHealthKitPermission = !self.nocturneManager.didRequestHealthKitPermission
                    }
                }
            }

            subscribeSetting(\.nocturneSyncHeartRate, on: $syncHeartRate) { syncHeartRate = $0 } didSet: { [weak self] _ in
                self?.nocturneManager.updateObservedMetrics()
            }

            subscribeSetting(\.nocturneSyncSteps, on: $syncSteps) { syncSteps = $0 } didSet: { [weak self] _ in
                self?.nocturneManager.updateObservedMetrics()
            }

            subscribeSetting(\.nocturneSyncSleep, on: $syncSleep) { syncSleep = $0 } didSet: { [weak self] _ in
                self?.nocturneManager.updateObservedMetrics()
            }

            subscribeSetting(\.nocturneUploadNightscoutData, on: $uploadNightscoutData) { uploadNightscoutData = $0 }

            Timer.publish(every: 30, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] date in self?.statusTick = date }
                .store(in: &lifetime)
        }

        /// "X ago" (or "Never") for the last successful sync of `metric`, re-evaluated whenever
        /// `statusTick` changes so the screen stays roughly current while it's open.
        func lastSyncedText(_ metric: NocturneSyncMetric) -> String {
            _ = statusTick
            return Self.agoText(NocturneSyncStatus.lastSynced(metric))
        }

        /// "X ago" (or "Never") for the last backfill of `metric`.
        func lastBackfilledText(_ metric: NocturneSyncMetric) -> String {
            _ = statusTick
            return Self.agoText(NocturneSyncStatus.lastBackfilled(metric))
        }

        /// Whether `metric` (a HealthKit-sourced metric) has data waiting to sync because Apple
        /// Health was locked the last time Trio tried — not merely "this happened once," but
        /// genuinely still pending as of the last attempt.
        func isPendingUnlock(_ metric: NocturneSyncMetric) -> Bool {
            _ = statusTick
            return NocturneSyncStatus.isPendingUnlock(metric)
        }

        /// "X ago" for when `metric` last had a sync skipped because the device was locked.
        func lastSkippedLockedText(_ metric: NocturneSyncMetric) -> String {
            _ = statusTick
            return Self.agoText(NocturneSyncStatus.lastSkippedLocked(metric))
        }

        private static func agoText(_ date: Date?) -> String {
            guard let date else {
                return String(localized: "Never")
            }
            let ago = String(localized: "ago", comment: "Relative time suffix, e.g. '5 m ago'")
            return "\(TimeAgoFormatter.minutesAgo(from: date)) \(ago)"
        }

        func connect() {
            if url.hasSuffix("/") {
                url = String(url.dropLast())
            }

            guard let validatedURL = URL(string: url), url.hasPrefix("https://") else {
                message = "Invalid URL"
                isValidURL = false
                return
            }

            connecting = true
            isValidURL = true
            message = ""

            provider.checkConnection(url: validatedURL, secret: secret.isEmpty ? nil : secret)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] completion in
                    guard let self else { return }
                    if case let .failure(error) = completion {
                        self.message = "Error: \(error.localizedDescription)"
                    }
                    self.connecting = false
                } receiveValue: { [weak self] in
                    guard let self else { return }
                    self.message = "Connected!"
                    self.keychain.setValue(self.url, forKey: Config.urlKey)
                    self.keychain.setValue(self.secret, forKey: Config.secretKey)
                    self.isConnected = true
                    self.nocturneManager.updateObservedMetrics()
                    self.nocturneManager.syncNow()
                }
                .store(in: &lifetime)
        }

        func backfillHealthData() async {
            await MainActor.run {
                backfilling = true
                message = ""
            }

            do {
                try await nocturneManager.backfillHealthData()
                await MainActor.run {
                    self.message = "Backfill complete!"
                }
            } catch {
                await MainActor.run {
                    self.message = "Error: \(error.localizedDescription)"
                }
            }

            await MainActor.run {
                self.backfilling = false
            }
        }

        func disconnect() {
            keychain.removeObject(forKey: Config.urlKey)
            keychain.removeObject(forKey: Config.secretKey)
            url = ""
            secret = ""
            isConnected = false
        }
    }
}
