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
                        "Trio reads these metrics from Apple Health and uploads them to Nocturne's Health API. Nightscout-compatible data (glucose, treatments, device status) is sent through the separate Nightscout connection, which also works against a Nocturne server URL."
                    )
                ) {
                    Toggle("Enable Nocturne Health Sync", isOn: $state.useNocturne)
                    if state.useNocturne {
                        Toggle("Heart Rate", isOn: $state.syncHeartRate)
                        Toggle("Steps", isOn: $state.syncSteps)
                        Toggle("Sleep", isOn: $state.syncSleep)
                    }
                }.listRowBackground(Color.chart)

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
