import SwiftUI
#if os(macOS)
import SystemConfiguration
#endif

/// What differs between the Mac and the iPad app in more than one place.

/// Puts `text` on the general pasteboard.
@MainActor func copyToPasteboard(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
}

/// Touch first (iPad): controls the Mac shows on hover stay visible.
#if os(iOS)
let isTouchUI = true
#else
let isTouchUI = false
#endif

extension View {
    /// The iPad pointer (trackpad, mouse) highlights the control under it, as system buttons do.
    @ViewBuilder func pointerHover() -> some View {
        #if os(iOS)
        hoverEffect(.highlight)
        #else
        self
        #endif
    }
}

/// The Equalizer or Visualizer shown over an iPad window (`PadWindow`): a new iPad window would cover the app.
@MainActor @Observable final class ToolSheet {
    var id: String?
}

extension EnvironmentValues {
    @Entry var toolSheet: ToolSheet?
}

extension FocusedValues {
    @Entry var toolSheet: ToolSheet?
}

/// `openWindow(id:)` for the Equalizer and Visualizer: a window on the Mac, a sheet over the window on iPad.
struct OpenToolWindow: DynamicProperty {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.toolSheet) private var sheet
    @FocusedValue(\.toolSheet) private var focusedSheet  // menu commands live outside the window

    @MainActor func callAsFunction(id: String) {
        if let sheet = sheet ?? focusedSheet { sheet.id = id } else { openWindow(id: id) }
    }
}

/// The app is in front: the active app on the Mac, in the foreground on iPad.
@MainActor var appIsActive: Bool {
    #if os(macOS)
    NSApp.isActive
    #else
    UIApplication.shared.applicationState == .active
    #endif
}

extension Notification.Name {
    #if os(macOS)
    static let appWillTerminate = NSApplication.willTerminateNotification
    /// Last chance to save: quitting on the Mac, going to the background on iPad (it can be ended there without notice).
    static let appWillQuit = NSApplication.willTerminateNotification
    static let appDidResignActive = NSApplication.didResignActiveNotification
    static let appDidBecomeActive = NSApplication.didBecomeActiveNotification
    #else
    static let appWillTerminate = UIApplication.willTerminateNotification
    static let appWillQuit = UIApplication.didEnterBackgroundNotification
    static let appDidResignActive = UIApplication.willResignActiveNotification
    static let appDidBecomeActive = UIApplication.didBecomeActiveNotification
    #endif
}

extension View {
    /// Esc: the exit command on the Mac, the Escape key of a hardware keyboard on iPad.
    func onEscape(_ action: @escaping () -> Void) -> some View {
        #if os(macOS)
        onExitCommand(perform: action)
        #else
        onKeyPress(.escape) { action(); return .handled }
        #endif
    }

    /// Edit > Delete on the Mac; on iPad lists delete from their menus.
    @ViewBuilder func onDeleteKey(_ action: @escaping () -> Void) -> some View {
        #if os(macOS)
        onDeleteCommand(perform: action)
        #else
        self
        #endif
    }

    /// Edit > Select All on the Mac.
    @ViewBuilder func onSelectAll(_ action: @escaping () -> Void) -> some View {
        #if os(macOS)
        onCommand(#selector(NSResponder.selectAll(_:)), perform: action)
        #else
        self
        #endif
    }

    /// Plays: a double-click on the Mac, a tap on iPad.
    func onPlayTap(_ action: @escaping () -> Void) -> some View {
        #if os(macOS)
        onTapGesture(count: 2, perform: action)
        #else
        onTapGesture(perform: action)
        #endif
    }
}

/// This device for the web remote: the address to open on the phone, and the name in Bonjour.
enum LocalHost {
    /// `name.local` on the Mac; the Wi-Fi IPv4 address on iPad.
    static var address: String? {
        #if os(macOS)
        (SCDynamicStoreCopyLocalHostName(nil) as String?).map { $0 + ".local" }
        #else
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = entry.pointee
            guard String(cString: a.ifa_name) == "en0", let addr = a.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        return nil
        #endif
    }

    @MainActor static var name: String {
        #if os(macOS)
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
        #else
        UIDevice.current.name
        #endif
    }
}

#if os(iOS)
/// AppKit names for the image calls of the shared code (covers, artwork, QR code), so it reads the same on iPad.
typealias NSImage = UIImage
typealias NSSize = CGSize

extension UIImage {
    convenience init(cgImage: CGImage, size: CGSize) { self.init(cgImage: cgImage) }
    convenience init?(contentsOf url: URL) { self.init(contentsOfFile: url.path) }
}

extension Image {
    init(nsImage: UIImage) { self.init(uiImage: nsImage) }
}

/// Screenshot runs (`scripts/shot.sh`) are Mac only.
enum Shot {
    static let output: String? = nil
    static let scene: String? = nil
}
#else
extension NSImage {
    /// The bitmap, as `UIImage` has it.
    var cgImage: CGImage? { cgImage(forProposedRect: nil, context: nil, hints: nil) }

    /// JPEG data, as `UIImage` has it.
    func jpegData(compressionQuality: CGFloat) -> Data? {
        tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?
            .representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }
}
#endif
