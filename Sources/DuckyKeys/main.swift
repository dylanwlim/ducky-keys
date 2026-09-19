import AppKit
import ServiceManagement
import KeyMapping
import Darwin

func bootSession() -> String {
    var size = 0
    guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return UUID().uuidString }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return UUID().uuidString }
    return String(cString: buffer)
}
struct Journal: Codable { var boot: String; var entries: [String: OwnedMapping] }

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let backend = HIDBackend()
    private var engine: MappingEngine!
    private var watcher: DeviceWatcher!
    private var retry: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var aboutWindow: NSWindow?
    private let defaults = UserDefaults.standard
    private var enabled: Bool { defaults.object(forKey: "enabled") as? Bool ?? true }
    private var names: [String] { defaults.stringArray(forKey: "bluetoothNames") ?? [] }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "com.dylanwlim.duckykeys").filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard others.isEmpty else { NSApp.terminate(nil); return }
        let boot = bootSession()
        let journal = defaults.data(forKey: "mappingJournal").flatMap { try? JSONDecoder().decode(Journal.self, from: $0) }
        engine = MappingEngine(backend: backend, owned: journal?.boot == boot ? journal!.entries : [:])
        engine.save = { [weak self] entries in
            guard let data = try? JSONEncoder().encode(Journal(boot: boot, entries: entries)) else { return }
            self?.defaults.set(data, forKey: "mappingJournal")
            self?.defaults.synchronize()
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Ducky Keys")
        statusItem.button?.toolTip = "Ducky Keys"
        statusItem.button?.setAccessibilityLabel("Ducky Keys")
        watcher = DeviceWatcher()
        watcher.onChange = { [weak self] in self?.scheduleRefresh() }
        for event in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in self?.scheduleRefresh() })
        }
        refresh()
        if !defaults.bool(forKey: "hasLaunched") {
            defaults.set(true, forKey: "hasLaunched")
            about()
        }
        if CommandLine.arguments.contains("--show-menu") { statusItem.button?.performClick(nil) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        about()
        return true
    }
    func scheduleRefresh() {
        refresh()
        retry?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
    func refresh() {
        engine.reconcile(enabled: enabled, savedNames: names)
        buildMenu()
    }
    func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        @discardableResult func item(_ title: String, _ action: Selector? = nil, enabled: Bool = true) -> NSMenuItem {
            let result = NSMenuItem(title: title, action: action, keyEquivalent: "")
            result.target = self; result.isEnabled = enabled
            menu.addItem(result); return result
        }
        item("Ducky Keys", enabled: false)
        let status: String
        if !engine.failures.isEmpty { status = "Mapping needs attention" }
        else if !enabled { status = "Paused" }
        else if engine.connected.isEmpty { status = "Waiting for your Ducky" }
        else { status = "Active · \(engine.connected.first!.name)" }
        item(status, enabled: false)
        statusItem.button?.toolTip = "Ducky Keys: \(status)"
        menu.addItem(.separator())
        item("Swap Control and Windows", #selector(toggle)).state = enabled ? .on : .off
        item("Left Control  →  Command ⌘", enabled: false)
        item("Left Windows  →  Control ⌃", enabled: false)
        if !engine.failures.isEmpty { item("Retry Mapping", #selector(retryMapping)) }
        menu.addItem(.separator())
        item("Bluetooth Keyboard…", #selector(bluetoothName))
        let login = item("Start at Login", #selector(toggleLogin))
        login.state = loginState
        if SMAppService.mainApp.status == .requiresApproval { item("Allow in Login Items…", #selector(openLoginSettings)) }
        item("Check for Updates", enabled: false)
        menu.addItem(.separator())
        item("About Ducky Keys…", #selector(about))
        let quit = item("Quit Ducky Keys", #selector(quit)); quit.keyEquivalent = "q"
        statusItem.menu = menu
    }
    private var loginState: NSControl.StateValue {
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .mixed
        default: return .off
        }
    }
    func menuWillOpen(_ menu: NSMenu) {
        if let item = menu.items.first(where: { $0.title == "Start at Login" }) { item.state = loginState }
        let title = "Allow in Login Items…"
        if SMAppService.mainApp.status == .requiresApproval && !menu.items.contains(where: { $0.title == title }) {
            let item = NSMenuItem(title: title, action: #selector(openLoginSettings), keyEquivalent: "")
            item.target = self
            let index = menu.items.firstIndex(where: { $0.title == "Start at Login" }) ?? 0
            menu.insertItem(item, at: index + 1)
        } else if SMAppService.mainApp.status != .requiresApproval, let item = menu.items.first(where: { $0.title == title }) {
            menu.removeItem(item)
        }
    }
    @objc func toggle() { defaults.set(!enabled, forKey: "enabled"); refresh() }
    @objc func retryMapping() { refresh() }
    @objc func bluetoothName() {
        let alert = NSAlert()
        alert.messageText = "Your Bluetooth keyboard"
        alert.informativeText = "Ducky-named keyboards are detected automatically. If yours was renamed, enter its exact Bluetooth name. Leave blank to use automatic detection."
        let field = NSTextField(string: names.first ?? "")
        field.placeholderString = "Bluetooth name"
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        field.setAccessibilityLabel("Bluetooth keyboard name")
        alert.accessoryView = field
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(name.isEmpty ? [] : [name], forKey: "bluetoothNames")
            refresh()
        }
    }
    @objc func toggleLogin() {
        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems(); return }
        do {
            if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let alert = NSAlert(); alert.messageText = "Couldn’t change Start at Login"
            alert.informativeText = error.localizedDescription; alert.runModal()
        }
        buildMenu()
    }
    @objc func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    @objc func about() {
        if aboutWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 350, height: 330), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "About Ducky Keys"; window.isReleasedWhenClosed = false
            let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 14
            stack.translatesAutoresizingMaskIntoConstraints = false
            let icon = NSImageView(image: NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)!)
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 36, weight: .regular)
            stack.addArrangedSubview(icon)
            let title = NSTextField(labelWithString: "Ducky Keys")
            title.font = .boldSystemFont(ofSize: 22); stack.addArrangedSubview(title)
            stack.addArrangedSubview(NSTextField(labelWithString: "Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0")"))
            let description = NSTextField(wrappingLabelWithString: "Your Ducky. Your Mac shortcuts.\nBluetooth, dongle, or USB.\n\nUse the keyboard icon in your menu bar.")
            description.alignment = .center; stack.addArrangedSubview(description)
            let credit = NSTextField(labelWithString: "")
            let text = NSMutableAttributedString(string: "Made by Dylan", attributes: [.font: NSFont.systemFont(ofSize: 13)])
            text.addAttribute(.link, value: URL(string: "https://dylanwlim.com")!, range: NSRange(location: 8, length: 5))
            credit.attributedStringValue = text; credit.isSelectable = true; credit.allowsEditingTextAttributes = true
            stack.addArrangedSubview(credit)
            let menuButton = NSButton(title: "Open Menu", target: self, action: #selector(showMenu))
            menuButton.bezelStyle = .rounded
            stack.addArrangedSubview(menuButton)
            window.contentView!.addSubview(stack)
            NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: window.contentView!.centerXAnchor), stack.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor), stack.widthAnchor.constraint(equalToConstant: 300)])
            window.center(); aboutWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); aboutWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func showMenu() { statusItem.button?.performClick(nil) }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard engine != nil else { return .terminateNow }
        engine.reconcile(enabled: false, savedNames: names)
        if !engine.failures.isEmpty {
            let alert = NSAlert(); alert.messageText = "Some keys could not be restored"
            alert.informativeText = "Another mapping may be active. Reconnect your Ducky to clear temporary mappings, or keep Ducky Keys open and try again."
            alert.addButton(withTitle: "Keep Open"); alert.addButton(withTitle: "Quit Anyway")
            if alert.runModal() == .alertFirstButtonReturn { refresh(); return .terminateCancel }
        }
        return .terminateNow
    }
}

if CommandLine.arguments.contains("--diagnostics") {
    let backend = HIDBackend()
    let scan = backend.keyboards()
    let keyboards = scan ?? []
    let names = UserDefaults.standard.stringArray(forKey: "bluetoothNames") ?? []
    let report: [String: Any] = ["enumerationSucceeded": scan != nil, "keyboardCount": keyboards.count, "duckyCount": keyboards.filter { $0.isDucky(savedNames: names) }.count,
        "startAtLogin": SMAppService.mainApp.status == .enabled,
        "enabled": UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true,
        "keyboards": keyboards.map { ["name": $0.name, "builtIn": $0.builtIn, "matched": $0.isDucky(savedNames: names), "mappingCount": backend.read($0.id)?.count ?? -1] as [String: Any] }]
    let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
