#if os(macOS)
import Foundation
import IOKit
import IOUSBHost

extension SysInfoExtended {
    nonisolated(unsafe) private static var usbCache: [String: SysInfoExtended] = [:]
    private static let lock = NSLock()

    /// Reads SysInfoExtended from the iPod over USB (vendor request 0x40, as libgpod does): iTunes and
    /// Finder do not write the file. Read-only; cached per USB serial for the life of the app.
    public static func readOverUSB(serial: String) -> SysInfoExtended? {
        if let hit = lock.withLock({ usbCache[serial] }) { return hit }
        guard let data = request(serial: serial), let info = SysInfoExtended(data: data) else { return nil }
        lock.withLock { usbCache[serial] = info }
        return info
    }

    private static func request(serial: String) -> Data? {
        // USB matching ignores idVendor alone (it needs fixed key combos), so filter by serial below.
        let matching = IOServiceMatching("IOUSBHostDevice")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let found = IORegistryEntryCreateCFProperty(service, "USB Serial Number" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard found == serial, let device = try? IOUSBHostDevice(__ioService: service, options: [], queue: nil, interestHandler: nil)
            else { continue }
            defer { device.destroy() }
            var out = Data()
            for page in 0..<64 {
                let request = IOUSBDeviceRequest(bmRequestType: 0xC0, bRequest: 0x40, wValue: 0x02, wIndex: UInt16(page), wLength: 0x1000)
                guard let buffer = NSMutableData(length: 0x1000) else { return nil }
                var count = 0
                guard (try? device.__send(request, data: buffer, bytesTransferred: &count, completionTimeout: 2)) != nil else { return nil }
                out.append(buffer.subdata(with: NSRange(location: 0, length: count)))
                if count < 0x1000 { break }
            }
            return out.isEmpty ? nil : out
        }
        return nil
    }
}
#else
import Foundation

extension SysInfoExtended {
    public static func readOverUSB(serial: String) -> SysInfoExtended? { nil }
}
#endif
