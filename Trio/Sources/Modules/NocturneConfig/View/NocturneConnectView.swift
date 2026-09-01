import SwiftUI

struct NocturneConnectView: View {
    @ObservedObject var state: NocturneConfig.StateModel

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

            if state.isConnected {
                Section {
                    Button {
                        UIApplication.shared.open(URL(string: state.url)!, options: [:], completionHandler: nil)
                    }
                    label: { Label("Open Nocturne", systemImage: "waveform.path.ecg.rectangle").font(.title3).padding() }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .buttonStyle(.bordered)
                }
                .listRowBackground(Color.clear)
            }
        }
        .listSectionSpacing(sectionSpacing)
        .navigationTitle("Connect")
        .navigationBarTitleDisplayMode(.automatic)
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
    }
}
