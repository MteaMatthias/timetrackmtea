// Nep-"Flow" (Telavox) voor de end-to-end-tests van TimeTrack.
//
// Toont één venster waarvan de toegankelijke teksten (Accessibility) het gesprekspaneel van Flow nabootsen,
// in dezelfde volgorde als de echte app. De test stuurt het verloop door een klein tekstbestand te schrijven:
//
//   <controlDir>/state     regels "sleutel=waarde", bv.
//                            state=ringing          (idle | ringing | active | gone | quit)
//                            number=0493 29 50 63   (optioneel)
//                            name=Matthias .        (optioneel)
//                            company=M&M            (optioneel)
//
// Het bestand wordt elke 0,1 s gelezen. Bij "active" telt een teller ("00:01", "00:02"…) op vanaf het moment
// dat de toestand actief werd, zoals in Flow. Verder schrijft de app:
//   <controlDir>/fakeflow.ready   (pid) zodra het venster staat
//   <controlDir>/openurl.txt      elke URL die macOS aan de app geeft (schema timetrack-e2e://, zie Info.plist)
//
// Gebruik: Flow.app/Contents/MacOS/Flow --control <dir>   (of via `open -a Flow.app --args --control <dir>`)
import AppKit

final class FakeFlow: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var timerLabel: NSTextField?
    private var state = "idle"
    private var fields: [String: String] = [:]
    private var activeSince = Date()
    private var lastRaw = ""
    private let controlDir: URL

    init(controlDir: URL) {
        self.controlDir = controlDir
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 80, y: 120, width: 360, height: 520),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Flow"
        window.isReleasedWhenClosed = false
        render()
        window.orderFrontRegardless()
        try? FileManager.default.createDirectory(at: controlDir, withIntermediateDirectories: true)
        try? "\(getpid())".write(to: controlDir.appendingPathComponent("fakeflow.ready"), atomically: true, encoding: .utf8)
        let poll = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(poll, forMode: .common)
        log("klaar, control=\(controlDir.path)")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// URL's met het schema timetrack-e2e:// (de test laat TimeTrack zo "de browser openen" bij het verbinden).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            log("URL ontvangen: \(url.absoluteString)")
            let line = url.absoluteString + "\n"
            for target in [controlDir.appendingPathComponent("openurl.txt"),
                           URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fakeflow-openurl.txt")] {
                if let handle = try? FileHandle(forWritingTo: target) {
                    handle.seekToEndOfFile()
                    handle.write(Data(line.utf8))
                    try? handle.close()
                } else {
                    try? line.write(to: target, atomically: true, encoding: .utf8)
                }
            }
        }
    }

    private func log(_ s: String) {
        FileHandle.standardError.write(Data("FakeFlow: \(s)\n".utf8))
    }

    private func poll() {
        let raw = (try? String(contentsOf: controlDir.appendingPathComponent("state"), encoding: .utf8)) ?? "state=idle"
        if raw != lastRaw {
            lastRaw = raw
            var parsed: [String: String] = [:]
            for line in raw.split(whereSeparator: \.isNewline) {
                guard let eq = line.firstIndex(of: "=") else { continue }
                parsed[String(line[..<eq]).trimmingCharacters(in: .whitespaces)] =
                    String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            }
            let newState = parsed["state"] ?? "idle"
            if newState == "quit" { NSApp.terminate(nil); return }
            if newState == "active" && state != "active" { activeSince = Date() }
            state = newState
            fields = parsed
            render()
            log("toestand \(state)")
        }
        if state == "active" { timerLabel?.stringValue = timerText() }
    }

    private func timerText() -> String {
        let s = max(0, Int(Date().timeIntervalSince(activeSince)))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// Bouwt het venster opnieuw op, van boven naar onder, in de volgorde waarin Flow zijn teksten toont.
    private func render() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 520))
        var y: CGFloat = 490
        timerLabel = nil
        func label(_ text: String, bold: Bool = false) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.font = bold ? .boldSystemFont(ofSize: 15) : .systemFont(ofSize: 13)
            l.frame = NSRect(x: 16, y: y, width: 328, height: 20)
            content.addSubview(l)
            y -= 26
            return l
        }
        func button(_ title: String) {
            let b = NSButton(title: title, target: nil, action: nil)
            b.bezelStyle = .rounded
            b.frame = NSRect(x: 16, y: y - 4, width: 160, height: 28)
            content.addSubview(b)
            y -= 34
        }
        // Wat altijd in Flow staat (geen gesprek): mag nooit als gesprek herkend worden.
        _ = label("Telavox Flow", bold: true)
        _ = label("Contacten")
        _ = label("Geschiedenis")

        let number = fields["number"] ?? "0493 29 50 63"
        let name = fields["name"] ?? "Matthias ."
        let company = fields["company"] ?? "M&M"
        let initials = (name.first.map { "\($0)." }) ?? "M."
        switch state {
        case "ringing":
            _ = label("Inkomende oproep", bold: true)
            _ = label(initials)
            _ = label(name)
            _ = label(company)
            _ = label(number)
            _ = label("Via")
            _ = label("Mtea - Verkoop")
            _ = label("Gewenst 003256446650")
            button("Verwijderen")
            button("Antwoorden")
        case "active":
            timerLabel = label(timerText(), bold: true)
            _ = label(initials)
            _ = label(name)
            _ = label(company)
            _ = label(number)
            _ = label("Via")
            _ = label("Mtea - Verkoop")
            _ = label("Gewenst 003256446650")
            button("Ophangen")
            button("Parkeren")
            button("Doorverbinden")
        default:
            _ = label("Geen lopende gesprekken")
        }
        window.contentView = content
    }
}

var controlPath = NSTemporaryDirectory() + "fakeflow"
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--control"), i + 1 < args.count { controlPath = args[i + 1] }
if let env = ProcessInfo.processInfo.environment["FAKEFLOW_CONTROL"], !env.isEmpty { controlPath = env }

let app = NSApplication.shared
let delegate = FakeFlow(controlDir: URL(fileURLWithPath: controlPath, isDirectory: true))
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
