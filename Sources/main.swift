import AppKit
import CoreGraphics

let usage = """
crisp-display: HiDPI nítido em monitores 1080p no macOS e Dock presa no monitor principal.

Uso:
  crisp-display list
      Lista os monitores conectados com o identificador fabricante:modelo.

  crisp-display run [--display FABRICANTE:MODELO] [--looks-like LARGURAxALTURA]
                    [--position below|above|left|right] [--no-dock-guard]
      Fica rodando em segundo plano.
      --display     monitor que vai ganhar HiDPI (veja em `list`). Sem ele, só a trava da Dock roda.
      --looks-like  tamanho da interface no monitor (padrão: 1344x756).
      --position    mantém o monitor HiDPI encostado nesse lado do principal.
      --no-dock-guard  não trava a Dock no monitor principal.
"""

func listDisplays() {
    let main = CGMainDisplayID()
    for id in Displays.online() {
        let bounds = CGDisplayBounds(id)
        let mode = CGDisplayCopyDisplayMode(id)
        let pixels = mode.map { "\($0.pixelWidth)x\($0.pixelHeight)" } ?? "?"
        var tags: [String] = []
        if id == main { tags.append("principal") }
        let mirrorOf = CGDisplayMirrorsDisplay(id)
        if mirrorOf != kCGNullDirectDisplay { tags.append("espelhando \(mirrorOf)") }
        let identifier = "\(CGDisplayVendorNumber(id)):\(CGDisplayModelNumber(id))"
        print("\(id)  \(identifier)  \(Displays.name(of: id))  interface \(Int(bounds.width))x\(Int(bounds.height)), pixels \(pixels)  \(tags.joined(separator: ", "))")
    }
}

func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n\n\(usage)\n".utf8))
    exit(64)
}

func run(_ arguments: [String]) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)

    var mirror: HiDPIMirror?
    if let displayText = value(after: "--display", in: arguments) {
        guard let target = DisplayMatch(displayText) else { fail("--display inválido: \(displayText)") }
        let sizeText = value(after: "--looks-like", in: arguments) ?? "1344x756"
        guard let looksLike = Size(sizeText) else { fail("--looks-like inválido: \(sizeText)") }
        let positionText = value(after: "--position", in: arguments)
        let placement = positionText.flatMap(Placement.init)
        if let positionText, placement == nil { fail("--position inválido: \(positionText)") }
        mirror = HiDPIMirror(target: target, looksLike: looksLike, placement: placement)
        mirror?.start()
    }

    var dockGuard: DockGuard?
    if !arguments.contains("--no-dock-guard") {
        dockGuard = DockGuard()
        dockGuard?.start()
    }

    for sig in [SIGTERM, SIGINT] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            mirror?.stop()
            exit(0)
        }
        source.resume()
        signalSources.append(source)
    }

    withExtendedLifetime((mirror, dockGuard)) { app.run() }
    exit(0)
}

var signalSources: [DispatchSourceSignal] = []
let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "list": listDisplays()
case "run": run(Array(arguments.dropFirst()))
case "-h", "--help", "help", nil: print(usage)
default: fail("comando desconhecido: \(arguments[0])")
}
