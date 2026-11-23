import Support
import SwiftUI
import WebKit

/// MilkDrop presets, rendered by butterchurn (`Resources/Visualizer`) in a web view that the app feeds with the tap's samples.
@Observable @MainActor final class MilkDrop: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    /// User presets: MilkDrop `.milk` files and butterchurn `.json` files. A `.milk` file is converted on the page
    /// (bundled converter, offline) the first time it loads; the result is kept next to it as `.json`.
    nonisolated static var userFolder: URL { Paths.appSupport("Visualizer Presets") }

    private(set) var presets: [String] = []
    private(set) var current: String?
    /// `.milk` presets the converter could not handle.
    private(set) var failed: [String] = []
    @ObservationIgnored weak var webView: WKWebView?
    /// A title and options sent before the page loaded; applied once it has.
    @ObservationIgnored private var pendingTitle: String?
    @ObservationIgnored private var config = "{}"
    @ObservationIgnored private var loaded = false

    func step(_ by: Int) { run("ms.step(\(by))") }
    func random() { run("ms.random()") }
    func select(_ name: String) { run("ms.select(\(Self.literal(name)))") }

    /// MilkDrop's song title animation: the text flies in and melts into the preset.
    func title(_ text: String) {
        guard loaded else { pendingTitle = text; return }
        run("ms.title(\(Self.literal(text)))")
    }

    /// The resource folder; the SwiftPM bundle is in `Contents/Resources` of the app, or next to the binary in a build.
    /// Not `Bundle.module`: `scripts/bundle.sh` type-checks the sources without SwiftPM's generated accessor.
    static var page: URL? {
        let url = Bundle.main.url(forResource: "MusicSync_MusicSyncApp", withExtension: "bundle")
            ?? Bundle.main.bundleURL.appendingPathComponent("MusicSync_MusicSyncApp.bundle")
        return Bundle(url: url)?.url(forResource: "index", withExtension: "html", subdirectory: "Visualizer")
    }

    /// JSON options for `ms.configure`.
    func configure(_ json: String) {
        config = json
        if loaded { run("ms.configure(\(json))") }
    }

    /// Sends the folder's presets: `.json` as they are, `.milk` without a `.json` to the converter.
    func loadUserPresets() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.userFolder, includingPropertiesForKeys: nil)) ?? []
        var extra: [String: Any] = [:]
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file), let preset = try? JSONSerialization.jsonObject(with: data) {
                extra[file.deletingPathExtension().lastPathComponent] = preset
            }
        }
        if !extra.isEmpty, let json = try? JSONSerialization.data(withJSONObject: extra), let text = String(data: json, encoding: .utf8) {
            run("ms.addPresets(\(text))")
        }
        for file in files where file.pathExtension == "milk" {
            let name = file.deletingPathExtension().lastPathComponent
            guard extra[name] == nil, !failed.contains(name),
                  let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { continue }
            run("ms.convert(\(Self.literal(name)), \(Self.literal(text)))")
        }
    }

    func feed(_ left: [Float], _ right: [Float]) {
        let byte = { (x: Float) in UInt8(max(min(128 + x * 127, 255), 0)) }
        let mono = Data(zip(left, right).map { byte(($0 + $1) / 2) })
        run("ms.feed('\(mono.base64EncodedString())','\(Data(left.map(byte)).base64EncodedString())','\(Data(right.map(byte)).base64EncodedString())')")
    }

    private func run(_ script: String) { webView?.evaluateJavaScript(script, completionHandler: nil) }

    private static func literal(_ text: String) -> String {
        (try? JSONSerialization.data(withJSONObject: [text])).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "''"
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if let names = body["presets"] as? [String] { presets = names }
        if let name = body["current"] as? String { current = name }
        if let name = body["converted"] as? String, let preset = body["preset"] as? String {
            try? Data(preset.utf8).write(to: Self.userFolder.appendingPathComponent(name).appendingPathExtension("json"))
        }
        if let name = body["failed"] as? String {
            failed.append(name)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        run("ms.configure(\(config))")
        if let pendingTitle { title(pendingTitle) }
        pendingTitle = nil
        loadUserPresets()
    }
}

struct MilkDropView: NSViewRepresentable {
    let player: Player
    let milkDrop: MilkDrop

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(milkDrop, name: "visualizer")
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = milkDrop
        milkDrop.webView = view
        if let page = MilkDrop.page { view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent()) }
        context.coordinator.start { [player, milkDrop] in
            let samples = player.mixer.equalizer.samples.latest(1024, at: player.mixer.time)
            milkDrop.feed(samples.left, samples.right)
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.timer?.invalidate()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "visualizer")
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Feeds the page 60 times a second.
    @MainActor final class Coordinator {
        var timer: Timer?

        func start(_ tick: @escaping @MainActor () -> Void) {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
        }
    }
}
