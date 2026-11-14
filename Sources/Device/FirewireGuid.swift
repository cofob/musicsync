import DiskArbitration
import Foundation
import IOKit

public enum FirewireGuid {
    /// Resolves the GUID: manual override, SysInfoExtended, SysInfo, then IOKit USB serial.
    public static func resolve(for device: IPodDevice, manualOverride: String?) -> [UInt8]? {
        resolveString(for: device, manualOverride: manualOverride).flatMap(parse)
    }

    /// Raw 16-hex-char string (uppercase, no `0x`) of the first source that gives a valid GUID.
    public static func resolveString(for device: IPodDevice, manualOverride: String?) -> String? {
        let sources: [() -> String?] = [
            { manualOverride },
            { device.sysInfoExtended?.fireWireGUID },
            { device.sysInfo?.firewireGuid },
            { usbSerial(forVolume: device.mountURL) },
        ]
        for source in sources {
            if let raw = source(), let bytes = parse(raw) { return bytes.map { String(format: "%02X", $0) }.joined() }
        }
        return nil
    }

    /// Parses 16 hex chars with optional `0x`; nil for anything else.
    public static func parse(_ string: String) -> [UInt8]? {
        var hex = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.lowercased().hasPrefix("0x") { hex.removeFirst(2) }
        guard hex.count == 16, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return bytes
    }

    /// USB serial of the Apple USB device that holds the volume's IOMedia.
    public static func usbSerial(forVolume url: URL) -> String? {
        appleUSBProperty(forVolume: url, "USB Serial Number") as? String
    }

    /// USB product id of the iPod (e.g. 0x1261 for every iPod classic).
    public static func usbProductID(forVolume url: URL) -> Int? {
        appleUSBProperty(forVolume: url, "idProduct") as? Int
    }

    private static func appleUSBProperty(forVolume url: URL, _ key: String) -> Any? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let bsd = DADiskGetBSDName(disk) else { return nil }
        let media = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsd))
        guard media != 0 else { return nil }
        defer { IOObjectRelease(media) }
        return value(key, inAncestorsOf: media)
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// Walks up the service plane; returns `key` of the first Apple (0x05AC) USB entry that has it.
    private static func value(_ key: String, inAncestorsOf start: io_registry_entry_t) -> Any? {
        IOObjectRetain(start)
        var entry = start
        while entry != 0 {
            if (property(entry, "idVendor") as? Int) == 0x05AC,
               let found = property(entry, key) {
                IOObjectRelease(entry)
                return found
            }
            var parent: io_registry_entry_t = 0
            let found = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS
            // Release the current entry, not the parent (a `defer` here ran after `entry = parent`).
            IOObjectRelease(entry)
            guard found else { return nil }
            entry = parent
        }
        return nil
    }
}
