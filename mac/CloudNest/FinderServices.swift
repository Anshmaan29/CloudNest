import AppKit

/// Finder Services pass selected file URLs into the same reviewed native flows.
/// Registering the service does not grant any background scan or deletion permission.
@MainActor
final class CloudNestServices: NSObject, NSApplicationDelegate {
    private var handler: ((URL, Bool) -> Void)?
    private var pending: (URL, Bool)?
    func installHandler(_ handler: @escaping (URL, Bool) -> Void) {
        self.handler = handler
        if let pending { self.pending = nil; handler(pending.0, pending.1) }
    }
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.servicesProvider = self }
    @objc func reviewFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], urls.count == 1, let url = urls.first, url.isFileURL else {
            error.pointee = "Select one local file, folder or CloudNest recovery manifest."; return
        }
        let restore = userData == "restore"
        if let handler { handler(url, restore) }
        else if pending == nil { pending = (url, restore) }
        else { error.pointee = "CloudNest is still loading a previous selection. Try again when it is ready."; return }
        NSApp.activate(ignoringOtherApps: true); NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }
}
