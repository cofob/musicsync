import Foundation
import Observation
import Subsonic

/// Internet radio stations of the server. The page shows only when the server lists stations, or the user is an admin
/// and may add some; a server without the endpoint hides it.
@MainActor @Observable
final class RadioModel {
    var stations: [RadioStation] = []
    /// Admins may add, change and delete stations.
    var canEdit = false
    /// Set by a failed listing; the page shows it with a retry.
    private(set) var error: String?
    /// True once the listing answered.
    var isLoaded = false

    var isVisible: Bool { isLoaded && (!stations.isEmpty || canEdit) }

    @ObservationIgnored private unowned let app: AppModel

    init(app: AppModel) { self.app = app }

    func load() async {
        guard let client = app.client else { stations = []; canEdit = false; isLoaded = false; return }
        async let admin = try? client.getUser(username: client.config.username).adminRole
        do {
            let list = try await client.getInternetRadioStations()
            let isAdmin = await admin ?? false
            guard client.baseURL == app.client?.baseURL else { return }
            stations = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            canEdit = isAdmin
            isLoaded = true
            error = nil
        } catch where !error.isCancellation {
            guard client.baseURL == app.client?.baseURL else { return }
            self.error = error.friendlyMessage
        } catch {}
    }

    func play(_ station: RadioStation) {
        guard let url = URL(string: station.streamUrl) else { return }
        app.player.play([.file(url, title: station.name, artist: "Internet Radio", album: nil)])
    }

    /// Adds a station (`id` nil) or changes one.
    func save(id: String?, name: String, streamUrl: String, homePageUrl: String?) async {
        guard let client = app.client else { return }
        do {
            if let id {
                try await client.updateInternetRadioStation(id: id, name: name, streamUrl: streamUrl, homePageUrl: homePageUrl)
            } else {
                try await client.createInternetRadioStation(name: name, streamUrl: streamUrl, homePageUrl: homePageUrl)
            }
            await load()
        } catch { app.report(error) }
    }

    func delete(_ station: RadioStation) async {
        do {
            try await app.client?.deleteInternetRadioStation(id: station.id)
            await load()
        } catch { app.report(error) }
    }
}

extension PlayItem {
    /// A stream without an end (internet radio): no progress bar, a "LIVE" label instead.
    var isLive: Bool {
        if case .file(let url, _, _, _) = self { return !url.isFileURL }
        return false
    }
}
