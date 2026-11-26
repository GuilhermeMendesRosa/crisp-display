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

/// Lado do monitor principal em que o monitor HiDPI deve ficar encostado.
enum Placement: String {
    case below, above, left, right

    func isAttached(_ bounds: CGRect, to main: CGRect) -> Bool {
        let overlapsHorizontally = bounds.maxX > main.minX && bounds.minX < main.maxX
        let overlapsVertically = bounds.maxY > main.minY && bounds.minY < main.maxY
        switch self {
        case .below: return abs(bounds.minY - main.maxY) < 1 && overlapsHorizontally
        case .above: return abs(bounds.maxY - main.minY) < 1 && overlapsHorizontally
        case .left: return abs(bounds.maxX - main.minX) < 1 && overlapsVertically
        case .right: return abs(bounds.minX - main.maxX) < 1 && overlapsVertically
        }
    }

    func centeredOrigin(for size: CGSize, beside main: CGRect) -> CGPoint {
        let centerX = (main.minX + (main.width - size.width) / 2).rounded()
        let centerY = (main.minY + (main.height - size.height) / 2).rounded()
        switch self {
        case .below: return CGPoint(x: centerX, y: main.maxY)
        case .above: return CGPoint(x: centerX, y: main.minY - size.height)
        case .left: return CGPoint(x: main.minX - size.width, y: centerY)
        case .right: return CGPoint(x: main.maxX, y: centerY)
        }
    }
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
