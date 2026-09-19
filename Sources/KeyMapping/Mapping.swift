import Foundation

public struct KeyMap: Codable, Equatable {
    public var source: UInt64
    public var destination: UInt64
    public init(_ source: UInt64, _ destination: UInt64) { self.source = source; self.destination = destination }
    public static let control: UInt64 = 0x7000000E0
    public static let command: UInt64 = 0x7000000E3
    public static let swap = [KeyMap(control, command), KeyMap(command, control)]
    public static func applying(to maps: [KeyMap]) -> [KeyMap] {
        maps.filter { $0.source != control && $0.source != command } + swap
    }
    public static func equivalent(_ a: [KeyMap], _ b: [KeyMap]) -> Bool {
        a.sorted { $0.source < $1.source } == b.sorted { $0.source < $1.source }
    }
}

public struct Keyboard: Equatable {
    public var id: String
    public var name: String
    public var vendor: Int
    public var product: Int
    public var transport: String
    public var builtIn: Bool
    public var isKeyboard: Bool
    public init(id: String, name: String, vendor: Int, product: Int, transport: String, builtIn: Bool, isKeyboard: Bool = true) {
        self.id = id; self.name = name; self.vendor = vendor; self.product = product
        self.transport = transport; self.builtIn = builtIn; self.isKeyboard = isKeyboard
    }
    public var fingerprint: String { "\(vendor):\(product):\(name):\(transport)" }
    public func isDucky(savedNames: [String]) -> Bool {
        let lower = name.lowercased()
        guard isKeyboard, !builtIn, vendor != 0x05ac,
              !lower.contains("virtual"), !lower.contains("karabiner") else { return false }
        // Exact pair from the existing Ducky configuration, never an OEM vendor alone.
        return (vendor == 0x3233 && product == 0x0018)
            || lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains("ducky")
            || (transport.lowercased().contains("bluetooth") && savedNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame })
    }
}

public struct OwnedMapping: Codable {
    public var fingerprint: String
    public var original: [KeyMap]
    public var applied: [KeyMap]
}

public protocol MappingBackend: AnyObject {
    // nil means enumeration failed; an empty array is a successful scan with no keyboards.
    func keyboards() -> [Keyboard]?
    func read(_ id: String) -> [KeyMap]?
    func write(_ id: String, maps: [KeyMap]) -> Bool
}

public final class MappingEngine {
    public var owned: [String: OwnedMapping]
    public var save: ([String: OwnedMapping]) -> Void = { _ in }
    public private(set) var failures: [String] = []
    public private(set) var connected: [Keyboard] = []
    private let backend: MappingBackend
    public init(backend: MappingBackend, owned: [String: OwnedMapping] = [:]) { self.backend = backend; self.owned = owned }
    public func reconcile(enabled: Bool, savedNames: [String]) {
        failures = []
        guard let devices = backend.keyboards() else {
            // A temporary HID error is not a disconnect. Keep the restoration journal intact.
            failures = ["Could not check connected keyboards"]
            return
        }
        let live = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        owned = owned.filter { live[$0.key]?.fingerprint == $0.value.fingerprint }
        connected = devices.filter { $0.isDucky(savedNames: savedNames) }
        for device in devices {
            guard let current = backend.read(device.id) else {
                if owned[device.id] != nil || device.isDucky(savedNames: savedNames) { failures.append(device.name) }
                continue
            }
            let shouldApply = enabled && device.isDucky(savedNames: savedNames)
            if let entry = owned[device.id] {
                if !shouldApply {
                    // Restore our two keys, preserving later edits to unrelated keys.
                    let sources = Set(KeyMap.swap.map(\.source))
                    let ours = current.filter { sources.contains($0.source) }
                    if KeyMap.equivalent(ours, KeyMap.swap) {
                        let restored = current.filter { !sources.contains($0.source) } + entry.original.filter { sources.contains($0.source) }
                        if !setAndVerify(device.id, restored) { failures.append(device.name); continue }
                    } else if !KeyMap.equivalent(current, entry.original) {
                        // Another tool owns these keys now. Do not overwrite it.
                        failures.append(device.name)
                    }
                    owned.removeValue(forKey: device.id)
                } else if !KeyMap.equivalent(current, entry.applied) {
                    if KeyMap.equivalent(current, entry.original) || current.isEmpty {
                        if !setAndVerify(device.id, entry.applied) { failures.append(device.name) }
                    } else if KeyMap.equivalent(current.filter { $0.source == KeyMap.control || $0.source == KeyMap.command }, KeyMap.swap) {
                        owned[device.id]?.applied = current
                    } else { failures.append(device.name) }
                }
            } else if shouldApply {
                let applied = KeyMap.applying(to: current)
                owned[device.id] = OwnedMapping(fingerprint: device.fingerprint, original: current, applied: applied)
                save(owned) // Journal before changing the live keyboard; survives a crash.
                if !setAndVerify(device.id, applied) { failures.append(device.name) }
            }
        }
        save(owned)
    }
    private func setAndVerify(_ id: String, _ maps: [KeyMap]) -> Bool {
        guard backend.write(id, maps: maps), let result = backend.read(id) else { return false }
        return KeyMap.equivalent(result, maps)
    }
}
