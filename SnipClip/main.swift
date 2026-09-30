import AppKit

let app = NSApplication.shared
#if DEBUG
// UI automation tools can't target accessory apps; opt in to a regular
// activation policy for test runs only.
app.setActivationPolicy(ProcessInfo.processInfo.environment["SNIPCLIP_UITEST"] == nil ? .accessory : .regular)
#else
app.setActivationPolicy(.accessory)
#endif
let delegate = AppDelegate()
app.delegate = delegate

/// Hidden for an accessory app, but still routes standard key equivalents
/// (⌘S, ⌘W, ⌘Z, ⌘C…) to the first responder in SnipClip's windows.
func buildMainMenu() -> NSMenu {
    let main = NSMenu()

    func submenu(_ title: String, _ items: [NSMenuItem]) {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach { menu.addItem($0) }
        holder.submenu = menu
        main.addItem(holder)
    }
    func item(_ title: String, _ action: Selector?, _ key: String,
              _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = target
        return i
    }

    submenu("SnipClip", [
        item("About SnipClip", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", target: NSApp),
        .separator(),
        item("Settings…", #selector(AppDelegate.showSettings), ",", target: delegate),
        .separator(),
        item("Quit SnipClip", #selector(NSApplication.terminate(_:)), "q", target: NSApp),
    ])
    submenu("File", [
        item("Save…", Selector(("saveDocument:")), "s"),
        item("Close", #selector(NSWindow.performClose(_:)), "w"),
    ])
    submenu("Edit", [
        item("Undo", Selector(("undo:")), "z"),
        item("Redo", Selector(("redo:")), "z", [.command, .shift]),
        .separator(),
        item("Cut", #selector(NSText.cut(_:)), "x"),
        item("Copy", #selector(NSText.copy(_:)), "c"),
        item("Paste", #selector(NSText.paste(_:)), "v"),
        item("Delete", #selector(NSText.delete(_:)), ""),
        item("Select All", #selector(NSText.selectAll(_:)), "a"),
    ])
    return main
}

app.mainMenu = buildMainMenu()
app.run()
