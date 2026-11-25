import AVKit
import SwiftUI
import Subsonic
import WebKit

#if os(macOS)
private typealias Representable = NSViewRepresentable
#else
private typealias Representable = UIViewRepresentable
#endif

/// A music video. With `follow` (the Now Playing background) it is muted, has no controls, and keeps to the song's
/// position and play state; else it plays with its own sound and controls. `onEnd(failed)`: it ended, or cannot play.
struct MusicVideoView: View {
    let video: MusicVideo
    var follow: (playing: Bool, time: TimeInterval)?
    var onEnd: (_ failed: Bool) -> Void = { _ in }
    @Environment(AppModel.self) private var model

    var body: some View {
        switch video {
        case .youtube(let id, let embed):
            YouTubeView(video: video, id: id, embed: embed, follow: follow, onEnd: onEnd)
        case .server(let id):
            if let client = model.client { ServerVideoView(video: video, url: client.streamURL(id: id), follow: follow) }
        }
    }
}

/// Tells when a song has no video. The video with its own sound (`AppModel.shownVideo`) goes on while Now Playing
/// is closed, and stops when the music plays: the two sounds do not play together.
struct MusicVideoPresenter: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content.alert("No Music Video", isPresented: $model.noVideoAlert) {} message: { Text("No video was found for this song.") }
            .onChange(of: model.player.isPlaying) { if $1 { model.shownVideo = nil } }
            .onChange(of: model.shownVideo) { if $0 != $1 { VideoKeeper.release() } }
    }
}

/// The player of the video with its own sound, kept while Now Playing is closed, so it plays on and comes back
/// in the same state.
@MainActor enum VideoKeeper {
    fileprivate static var web: (video: MusicVideo, view: WKWebView, coordinator: YouTubeView.Coordinator)?
    fileprivate static var player: (video: MusicVideo, player: AVPlayer)?

    static func release() {
        web?.view.pauseAllMediaPlayback()
        web = nil
        player?.player.pause()
        player = nil
    }
}

/// The player page of the Invidious or Piped instance that found the video, else YouTube's embed page (when the
/// instance's does not load or play), in a web view without stored data, with YouTube ads and trackers blocked.
private struct YouTubeView: Representable {
    let video: MusicVideo
    let id: String
    let embed: URL?
    let follow: (playing: Bool, time: TimeInterval)?
    let onEnd: (Bool) -> Void

    /// Compiled once.
    @MainActor private static var rules: WKContentRuleList?

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var web: WKWebView?
        var id = "", embed: URL?, background = false
        var onEnd: (Bool) -> Void = { _ in }
        /// On YouTube's own page: a failure there is the end.
        private var onYouTube = false

        func load() {
            guard let web else { return }
            let params = [("autoplay", "1"), ("playsinline", "1"), ("rel", "0"), ("iv_load_policy", "3"), ("modestbranding", "1"),
                          ("controls", background ? "0" : "1"), ("mute", background ? "1" : "0"), ("disablekb", background ? "1" : "0")]
            if let embed, !onYouTube {
                var url = URLComponents(url: embed, resolvingAgainstBaseURL: false)!
                url.queryItems = (params + [("local", "true")]).map { URLQueryItem(name: $0, value: $1) }  // Invidious: video through the instance
                web.load(URLRequest(url: url.url!))
                return
            }
            onYouTube = true
            var url = URLComponents(string: "https://www.youtube-nocookie.com/embed/\(id)")!
            url.queryItems = params.map { URLQueryItem(name: $0, value: $1) }
            var request = URLRequest(url: url.url!)
            request.setValue("https://github.com/cofob/musicsync", forHTTPHeaderField: "Referer")  // embeds without one do not play
            web.load(request)
        }

        private func failed() {
            if onYouTube { onEnd(true) } else { onYouTube = true; load() }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.body as? String == "error" { failed() } else { onEnd(false) }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed() }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            if response.isForMainFrame, let status = (response.response as? HTTPURLResponse)?.statusCode, status >= 400 { failed(); return .cancel }
            return .allow
        }
    }

    /// The sound mode's player stays in `VideoKeeper`.
    private var kept: (video: MusicVideo, view: WKWebView, coordinator: Coordinator)? {
        follow == nil ? VideoKeeper.web.flatMap { $0.video == video ? $0 : nil } : nil
    }

    func makeCoordinator() -> Coordinator { kept?.coordinator ?? Coordinator() }

    private func make(_ coordinator: Coordinator) -> WKWebView {
        if let kept {
            kept.view.removeFromSuperview()
            return kept.view
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = []
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        #endif
        let content = config.userContentController
        let muted = "window.musicSyncMuted = \(follow != nil);"
        content.addUserScript(WKUserScript(source: muted + YouTubeAdBlock.script + Self.control, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        content.add(coordinator, name: "video")
        let web = WKWebView(frame: .zero, configuration: config)
        #if DEBUG
        web.isInspectable = true
        #endif
        web.navigationDelegate = coordinator
        coordinator.web = web
        coordinator.id = id
        coordinator.embed = embed
        coordinator.background = follow != nil
        coordinator.onEnd = onEnd
        if follow == nil { VideoKeeper.web = (video, web, coordinator) }
        Task { @MainActor in
            if Self.rules == nil {
                Self.rules = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "youtube-ads", encodedContentRuleList: YouTubeAdBlock.rules)
            }
            if let rules = Self.rules { content.add(rules) }
            coordinator.load()
        }
        return web
    }

    private func update(_ web: WKWebView, _ coordinator: Coordinator) {
        coordinator.onEnd = onEnd
        guard let follow else { return }
        web.evaluateJavaScript("window.follow && follow(\(follow.playing), \(follow.time))")
    }

    /// Works on the `<video>` of any of the pages. `follow(playing, time)` keeps it at the song's position (not
    /// during a YouTube ad); in the background every play starts muted. Reports the end, and an error when the
    /// video fails or does not load in 20 s.
    private static let control = """
        (() => {
          if (window.top !== window) return;
          const ad = () => document.querySelector('.ad-showing') !== null;
          if (window.musicSyncMuted) document.addEventListener('play', e => { e.target.muted = true; }, true);
          window.follow = (playing, time) => {
            const video = document.querySelector('video');
            if (!video || ad()) return;
            video.muted = true;
            if (Math.abs(video.currentTime - time) > 2 && time < video.duration) video.currentTime = time;
            if (playing && video.paused && !video.ended) video.play(); else if (!playing && !video.paused) video.pause();
          };
          let sent = false;
          const send = m => { if (!sent) { sent = true; webkit.messageHandlers.video.postMessage(m); } };
          document.addEventListener('error', e => { if (e.target.tagName === 'VIDEO') send('error'); }, true);
          const started = Date.now();
          setInterval(() => {
            const video = document.querySelector('video');
            if (document.querySelector('.ytp-error') || (Date.now() - started > 20000 && (!video || video.readyState < 1))) send('error');
            if (video && video.ended && !ad()) send('ended');
          }, 1000);
        })();
        """

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { make(context.coordinator) }
    func updateNSView(_ web: WKWebView, context: Context) { update(web, context.coordinator) }
    #else
    func makeUIView(context: Context) -> WKWebView { make(context.coordinator) }
    func updateUIView(_ web: WKWebView, context: Context) { update(web, context.coordinator) }
    #endif
}

/// A video on the server: with controls, or (following the song) muted without them.
private struct ServerVideoView: View {
    let video: MusicVideo
    let url: URL
    let follow: (playing: Bool, time: TimeInterval)?
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                if follow != nil { PlayerLayer(player: player) } else { VideoPlayer(player: player) }
            }
        }
        .onAppear {
            if follow == nil, let kept = VideoKeeper.player, kept.video == video { player = kept.player; return }
            let player = AVPlayer(url: url)
            player.isMuted = follow != nil
            if follow == nil { player.play(); VideoKeeper.player = (video, player) }
            self.player = player
        }
        .onDisappear { if follow != nil { player?.pause() } }
        .onChange(of: follow?.time) {
            guard let follow, let player else { return }
            if abs(player.currentTime().seconds - follow.time) > 2 { player.seek(to: CMTime(seconds: follow.time, preferredTimescale: 600)) }
            if follow.playing != (player.rate != 0) { follow.playing ? player.play() : player.pause() }
        }
    }
}

/// A plain video layer, without the controls of `VideoPlayer`.
private struct PlayerLayer: Representable {
    let player: AVPlayer

    #if os(macOS)
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
    #else
    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
    }
    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        (view.layer as? AVPlayerLayer)?.player = player
        (view.layer as? AVPlayerLayer)?.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ view: LayerView, context: Context) {}
    #endif
}
