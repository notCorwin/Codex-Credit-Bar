import AppKit

@main
@MainActor
struct CodexMenuBarCreditMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = CodexMenuBarCreditAppDelegate()
        application.delegate = delegate
        application.run()
    }
}
