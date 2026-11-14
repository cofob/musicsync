import SwiftUI
import Subsonic

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralSettingsView().tabItem { Label("General", systemImage: "gearshape") }
            ServerSettingsView().tabItem { Label("Server", systemImage: "server.rack") }
            LibrarySettingsView().tabItem { Label("Library", systemImage: "books.vertical") }
            DownloadSettingsView().tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
            SyncSettingsView().tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
            ShortcutsSettingsView().tabItem { Label("Shortcuts", systemImage: "keyboard") }
            if model.system.sharesSupported { SharesSettingsView().tabItem { Label("Sharing", systemImage: "square.and.arrow.up") } }
        }
    }
}

private struct ServerSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var hasStoredPassword = false
    @State private var status: Status = .idle

    private enum Status {
        case idle, testing, ok(String), failed(String)
    }

    var body: some View {
        Form {
            Section("Navidrome Server") {
                TextField("Server URL", text: $url, prompt: Text("https://music.example.com"))
                    .textContentType(.URL).autocorrectionDisabled()
                TextField("Username", text: $username).autocorrectionDisabled()
                SecureField("Password", text: $password, prompt: Text(hasStoredPassword ? "Stored in Keychain" : ""))
            }
            Section {
                HStack {
                    Button("Test Connection") { Task { await test() } }.disabled(config == nil)
                    Button("Save") { Task { await save() } }.disabled(config == nil).keyboardShortcut(.defaultAction)
                    statusView
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            url = model.config?.baseURL.absoluteString ?? ""
            username = model.config?.username ?? ""
            hasStoredPassword = model.config?.password != nil
        }
    }

    @ViewBuilder private var statusView: some View {
        switch status {
        case .idle: EmptyView()
        case .testing: ProgressView().controlSize(.small)
        case .ok(let text): Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let text): Label(text, systemImage: "xmark.circle.fill").foregroundStyle(.red).lineLimit(2)
        }
    }

    /// Entered address; `https://` is assumed when the scheme is missing.
    private var config: ServerConfig? {
        var text = url.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty, !text.contains("://") { text = "https://" + text }
        guard let base = URL(string: text), base.host != nil, !username.isEmpty else { return nil }
        return ServerConfig(baseURL: base, username: username)
    }

    private func test() async {
        guard let config else { return }
        guard let pw = password.isEmpty ? config.password : password else { return status = .failed("Enter a password") }
        status = .testing
        let client = SubsonicClient(baseURL: config.baseURL, username: config.username, password: pw)
        do {
            let info = try await client.ping()
            let server = [info.type?.capitalized, info.serverVersion].compactMap { $0 }.joined(separator: " ")
            status = .ok([server.isEmpty ? "Connected" : server, info.openSubsonic == true ? "OpenSubsonic" : nil]
                .compactMap { $0 }.joined(separator: " · "))
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func save() async {
        guard let config else { return }
        await model.save(config, password: password)
        password = ""
        hasStoredPassword = model.config?.password != nil
        status = .ok("Saved")
    }
}
