import SwiftUI
import Swinject

extension NocturneConfig {
    struct RootView: BaseView {
        let resolver: Resolver
        @StateObject var state = StateModel()

        @State var backfillAlert: Alert?
        @State var isBackfillAlertPresented = false

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        private var hasAnyPendingUnlock: Bool {
            (state.syncHeartRate && state.isPendingUnlock(.heartRate)) ||
                (state.syncSteps && state.isPendingUnlock(.steps)) ||
                (state.syncSleep && state.isPendingUnlock(.sleep))
        }

        private var syncStatusFooter: Text? {
            guard state.useNocturne, hasAnyPendingUnlock else { return nil }
            return Text(
                "Apple restricts background access to Health data while your iPhone is locked. Trio retries automatically the moment you unlock it — no action needed."
            )
        }

        private var backfillStatusCaption: String {
            var parts: [String] = []
            if state.syncHeartRate {
                parts.append("\(String(localized: "Heart Rate")): \(state.lastBackfilledText(.heartRate))")
            }
            if state.syncSteps {
                parts.append("\(String(localized: "Steps")): \(state.lastBackfilledText(.steps))")
            }
            if state.syncSleep {
                parts.append("\(String(localized: "Sleep")): \(state.lastBackfilledText(.sleep))")
            }
            return parts.joined(separator: "  ·  ")
        }

        var body: some View {
            List {
                Section(
                    header: Text("Connect to Nocturne"),
                    content: {
                        HStack {
                            TextField("URL", text: $state.url)
                                .disableAutocorrection(true)
                                .textContentType(.URL)
                                .autocapitalization(.none)
                                .keyboardType(.URL)
                            if state.message.isNotEmpty, !state.isValidURL {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                        SecureField("API Secret or Token", text: $state.secret)
                            .disableAutocorrection(true)
                            .autocapitalization(.none)
                            .textContentType(.password)
                            .keyboardType(.asciiCapable)
                        if state.message.isNotEmpty {
                            Text(state.message)
                        }
                        if state.connecting {
                            HStack {
                                Text("Connecting...")
                                Spacer()
                                ProgressView()
                            }
                        }

                        if !state.isConnected {
                            Button {
                                state.connect()
                            } label: {
                                Text("Connect to Nocturne")
                                    .font(.title3)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .buttonStyle(.bordered)
                            .disabled(state.url.isEmpty || state.connecting)
                        } else {
                            Button(role: .destructive) {
                                state.disconnect()
                            } label: {
                                Text("Disconnect and Remove")
                                    .font(.title3)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .buttonStyle(.bordered)
                            .tint(Color.loopRed)
                        }
                    }
                ).listRowBackground(Color.chart)

                Section(
                    header: Text("Health Data Sync"),
                    footer: Text(
                        "Trio reads these metrics from Apple Health and uploads them to Nocturne's Health API, which Nightscout has no equivalent for."
                    )
                ) {
                    Toggle("Enable Nocturne Health Sync", isOn: $state.useNocturne)
                    if state.useNocturne {
                        Toggle("Heart Rate", isOn: $state.syncHeartRate)
                        Toggle("Steps", isOn: $state.syncSteps)
                        Toggle("Sleep", isOn: $state.syncSleep)
                    }
                }.listRowBackground(Color.chart)

                Section(
                    header: Text("Nightscout Data"),
                    footer: Text(
                        "Nocturne mirrors the Nightscout API, so Trio can send glucose, treatments, device status, and your therapy profile straight to Nocturne using the connection above — no separate Nightscout connection required. Leave this off if you'd rather keep using the Nightscout connection for that data (it works against a Nocturne URL too)."
                    )
                ) {
                    Toggle("Upload Nightscout Data", isOn: $state.uploadNightscoutData)
                }.listRowBackground(Color.chart)

                if state.isConnected, state.useNocturne || state.uploadNightscoutData {
                    Section(
                        header: Text("Sync Status"),
                        footer: syncStatusFooter
                    ) {
                        if state.useNocturne {
                            if state.syncHeartRate {
                                NocturneHealthMetricStatusRow(key: String(localized: "Heart Rate"), state: state, metric: .heartRate)
                            }
                            if state.syncSteps {
                                NocturneHealthMetricStatusRow(key: String(localized: "Steps"), state: state, metric: .steps)
                            }
                            if state.syncSleep {
                                NocturneHealthMetricStatusRow(key: String(localized: "Sleep"), state: state, metric: .sleep)
                            }
                        }
                        if state.uploadNightscoutData {
                            KeyValueRow(key: String(localized: "Glucose"), value: state.lastSyncedText(.glucose))
                            KeyValueRow(key: String(localized: "Treatments"), value: state.lastSyncedText(.treatments))
                            KeyValueRow(key: String(localized: "Device Status"), value: state.lastSyncedText(.deviceStatus))
                            KeyValueRow(key: String(localized: "Profile"), value: state.lastSyncedText(.profile))
                        }
                    }.listRowBackground(Color.chart)
                }

                if state.useNocturne, state.isConnected {
                    Section(
                        content: {
                            VStack {
                                Button {
                                    Task {
                                        await state.backfillHealthData()
                                        if state.message.hasPrefix("Error:") {
                                            DispatchQueue.main.async {
                                                backfillAlert = Alert(
                                                    title: Text("Backfill Failed"),
                                                    message: Text(state.message),
                                                    dismissButton: .default(Text("OK"))
                                                )
                                                isBackfillAlertPresented = true
                                            }
                                        }
                                    }
                                } label: {
                                    Text("Backfill Health Data")
                                        .font(.title3)
                                }
                                .frame(maxWidth: .infinity, alignment: .center)
                                .buttonStyle(.bordered)
                                .disabled(state.connecting || state.backfilling)

                                HStack(alignment: .center) {
                                    Text(
                                        "Upload the last 24 hours of enabled metrics from Apple Health to Nocturne."
                                    )
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                    .lineLimit(nil)
                                    Spacer()
                                    if state.backfilling {
                                        ProgressView()
                                    }
                                }.padding(.top)

                                Text(backfillStatusCaption)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 2)
                            }.padding(.vertical)
                        }
                    ).listRowBackground(Color.chart)
                }

                if state.useNocturne, state.needsHealthKitPermission {
                    Section {
                        VStack {
                            HStack {
                                Image(systemName: "exclamationmark.circle.fill")
                                Text("Give Apple Health Read Permissions")
                            }.padding(.bottom)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("1. Open the Settings app on your iOS device.")
                                Text(
                                    "2. Scroll down or type \"Health\" in the settings search bar and select the \"Health\" app."
                                )
                                Text("3. Tap on \"Data Access & Devices\".")
                                Text("4. Find and select \"Trio\" from the list of apps.")
                                Text("5. Ensure Steps, Heart Rate, and Sleep Analysis are enabled under \"Read Data\".")
                            }.font(.footnote)
                        }
                        .padding(.vertical)
                        .foregroundColor(Color.secondary)
                    }.listRowBackground(Color.chart)
                }
            }
            .listSectionSpacing(sectionSpacing)
            .alert(isPresented: $isBackfillAlertPresented) {
                backfillAlert ?? Alert(title: Text("Unknown Error"))
            }
            .navigationBarTitle("Nocturne")
            .navigationBarTitleDisplayMode(.automatic)
            .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
            .onAppear(perform: configureView)
        }
    }
}

/// A `KeyValueRow` for a HealthKit-sourced metric that also flags when its sync is pending
/// because the device was locked, instead of just quietly showing a stale timestamp.
private struct NocturneHealthMetricStatusRow: View {
    let key: String
    @ObservedObject var state: NocturneConfig.StateModel
    let metric: NocturneSyncMetric

    var body: some View {
        HStack {
            Text(key)
                .foregroundColor(.primary)
            if state.isPendingUnlock(metric) {
                Image(systemName: "lock.fill")
                    .foregroundColor(.orange)
                    .font(.caption2)
            }
            Spacer()
            Text(state.isPendingUnlock(metric) ? String(localized: "Waiting for unlock") : state.lastSyncedText(metric))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}
