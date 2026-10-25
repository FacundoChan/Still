import StillEditor
import SwiftUI

@main
struct StillApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var coordinator = WindowCoordinator.shared

    var body: some Scene {
        // One window per video.
        WindowGroup(for: EditorWindowRequest.self) { $request in
            EditorWindow(request: request)
                .environment(coordinator)
        }
        // Opened files go through AppDelegate and WindowCoordinator; without this, SwiftUI would also
        // open an extra empty window for each one.
        .handlesExternalEvents(matching: [])
        .defaultSize(width: 1100, height: 760)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
        .commands {
            EditorCommands()
        }
    }
}

/// Receives videos opened from Finder or dropped on the Dock icon, and asks before quitting with unsaved edits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Nothing can be using the scratch folders yet; clear what a crash or forced quit left behind.
        TemporaryFiles.removeAll()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard WindowCoordinator.shared.needsQuitConfirmation else { return .terminateNow }
        Task {
            let proceed = await WindowCoordinator.shared.confirmQuit()
            sender.reply(toApplicationShouldTerminate: proceed)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // Automation hook for checking both appearances: `-StillAppearance dark` or `light`.
        switch UserDefaults.standard.string(forKey: "StillAppearance") {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        #endif
    }

    /// Each window is one video; with none left, Still has nothing to show, so it quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        WindowCoordinator.shared.openExternal(urls)
    }
}
