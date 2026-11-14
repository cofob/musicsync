import SwiftUI
import Subsonic

/// Settings window: a sidebar of pages with a search field, as in System Settings.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var page: SettingsPage
    @State private var query: String

    init(page: SettingsPage = .general, query: String = "") {
        _page = State(initialValue: query.isEmpty ? page : SettingsPage.allCases.first { $0.matches(query) } ?? page)
        _query = State(initialValue: query)
    }

    var body: some View {
        let pages = SettingsPage.allCases.filter { ($0 != .sharing || model.system.sharesSupported) && $0.matches(query) }
        NavigationSplitView {
            List {
                ForEach(pages) { item in
                    Label { Text(item.title) } icon: { SettingsIcon(page: item) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle().inset(by: -8))
                        .onTapGesture { page = item }
                        .accessibilityAddTraits(page == item ? [.isButton, .isSelected] : .isButton)
                        // Gray like the main sidebar, not the system blue.
                        .listRowBackground(RoundedRectangle(cornerRadius: 6).fill(page == item ? Color.primary.opacity(0.1) : .clear)
                            .padding(.horizontal, 10))
                }
            }
            .searchable(text: $query, placement: .sidebar)
            .overlay { if pages.isEmpty { ContentUnavailableView.search(text: query) } }
            .navigationSplitViewColumnWidth(200)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            ScrollView { Self.content(page).frame(maxWidth: .infinity) }
                .navigationTitle(page.title)
                .id(page)
        }
        .onChange(of: query) { if let first = pages.first, !pages.contains(page) { page = first } }
        .frame(width: 720, height: 600)
        .tint(Color.musicAccent)
    }

    /// The page alone; also used by the screenshot scenes.
    @ViewBuilder static func content(_ page: SettingsPage) -> some View {
        switch page {
        case .general: GeneralSettingsView()
        case .appearance: AppearanceSettingsView()
        case .playback: PlaybackSettingsView()
        case .server: ServerSettingsView()
        case .library: LibrarySettingsView()
        case .downloads: DownloadSettingsView()
        case .sync: SyncSettingsView()
        case .shortcuts: ShortcutsSettingsView()
        case .remote: RemoteSettingsView()
        case .sharing: SharesSettingsView()
        case .advanced: AdvancedSettingsView()
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
            status = .failed(error.friendlyMessage)
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
