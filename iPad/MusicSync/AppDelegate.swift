import Support
import UIKit

/// The iPad app: starts the services that the Mac starts in `applicationDidFinishLaunching`.
/// Here and not in a view, because Shortcuts can launch the app in the background without a window.
@MainActor final class AppDelegate: UIResponder, UIApplicationDelegate {
    let model = AppModel()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AudioSession.start(model.player)
        model.system.start()
        model.remote.start()
        // Downloads can be loaded again; they stay out of the device backup.
        var downloads = Paths.appSupport("downloads")
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? downloads.setResourceValues(values)
        return true
    }

    /// Edit > Find (⌘F) goes to the search field, as Search does on the Mac.
    override func find(_ sender: Any?) { model.searchFocusRequest += 1 }
}
