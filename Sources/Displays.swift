import AppKit
import CoreGraphics

/// Identifica um monitor pelo par fabricante:modelo do EDID (ex.: "7908:320").
/// Continua valendo quando o monitor está espelhado, ao contrário do nome do NSScreen.
struct DisplayMatch: CustomStringConvertible {
    let vendor: UInt32
    let model: UInt32

    init?(_ text: String) {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let vendor = UInt32(parts[0]), let model = UInt32(parts[1]) else { return nil }
        self.vendor = vendor
        self.model = model
    }

    func matches(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == vendor && CGDisplayModelNumber(id) == model
    }

    var description: String { "\(vendor):\(model)" }
}

struct Size: CustomStringConvertible {
    let width: Int
    let height: Int

    init?(_ text: String) {
        let parts = text.lowercased().split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]), width > 0, height > 0 else { return nil }
        self.width = width
        self.height = height
    }

    var description: String { "\(width)x\(height)" }
}

enum Displays {
    static func online() -> [CGDirectDisplayID] {
        list(CGGetOnlineDisplayList)
    }

    static func active() -> [CGDirectDisplayID] {
        list(CGGetActiveDisplayList)
    }

    /// Telas que aparecem no arranjo: as ativas que não estão espelhando outra.
    static func arranged() -> [CGDirectDisplayID] {
        active().filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
    }

    static func name(of id: CGDirectDisplayID) -> String {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
        return screen?.localizedName ?? "?"
    }

    private static func list(_ fetch: (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError) -> [CGDirectDisplayID] {
        let capacity: UInt32 = 32
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(capacity))
        var count: UInt32 = 0
        guard fetch(capacity, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    print("[\(stamp)] \(message)")
    fflush(stdout)
}
