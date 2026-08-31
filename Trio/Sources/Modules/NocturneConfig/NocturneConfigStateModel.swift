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

        @Published var useNocturne = false
        @Published var syncHeartRate = true
        @Published var syncSteps = true
        @Published var syncSleep = true
        @Published var needsHealthKitPermission = false

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

        func disconnect() {
            keychain.removeObject(forKey: Config.urlKey)
            keychain.removeObject(forKey: Config.secretKey)
            url = ""
            secret = ""
            isConnected = false
        }
    }
}
