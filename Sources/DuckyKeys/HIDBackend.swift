import Foundation
import IOKit
import IOKit.hidsystem
import KeyMapping

final class HIDBackend: MappingBackend {
    private let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    private var services: [String: IOHIDServiceClient] = [:]
    func keyboards() -> [Keyboard]? {
        guard let all = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] else { return nil }
        services = [:]
        return all.compactMap { service in
            guard IOHIDServiceClientConformsTo(service, 1, 6) != 0 else { return nil }
            func prop(_ name: String) -> Any? { IOHIDServiceClientCopyProperty(service, name as CFString) }
            let id = String(describing: IOHIDServiceClientGetRegistryID(service))
            services[id] = service
            return Keyboard(id: id, name: prop("Product") as? String ?? "Keyboard", vendor: (prop("VendorID") as? NSNumber)?.intValue ?? 0, product: (prop("ProductID") as? NSNumber)?.intValue ?? 0, transport: prop("Transport") as? String ?? "Unknown", builtIn: (prop("Built-In") as? NSNumber)?.boolValue ?? false)
        }
    }
    func read(_ id: String) -> [KeyMap]? {
        guard let service = services[id] else { return nil }
        guard let raw = IOHIDServiceClientCopyProperty(service, "UserKeyMapping" as CFString) else { return [] }
        guard let array = raw as? [[String: NSNumber]] else { return nil }
        var maps: [KeyMap] = []
        for value in array {
            guard let from = value["HIDKeyboardModifierMappingSrc"], let to = value["HIDKeyboardModifierMappingDst"] else { return nil }
            maps.append(KeyMap(from.uint64Value, to.uint64Value))
        }
        return maps
    }
    func write(_ id: String, maps: [KeyMap]) -> Bool {
        guard let service = services[id] else { return false }
        let raw = maps.map { ["HIDKeyboardModifierMappingSrc": NSNumber(value: $0.source), "HIDKeyboardModifierMappingDst": NSNumber(value: $0.destination)] }
        return IOHIDServiceClientSetProperty(service, "UserKeyMapping" as CFString, raw as CFArray)
    }
}

final class DeviceWatcher {
    var onChange: (() -> Void)?
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var fallbackTimer: DispatchSourceTimer?
    init() {
        port = IONotificationPortCreate(kIOMainPortDefault)
        guard let port else { startFallback(); return }
        IONotificationPortSetDispatchQueue(port, .main)
        for kind in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            let result = IOServiceAddMatchingNotification(port, kind, IOServiceMatching("IOHIDEventService"), { context, iterator in
                while case let object = IOIteratorNext(iterator), object != 0 { IOObjectRelease(object) }
                guard let context else { return }
                Unmanaged<DeviceWatcher>.fromOpaque(context).takeUnretainedValue().onChange?()
            }, Unmanaged.passUnretained(self).toOpaque(), &iterator)
            if result == KERN_SUCCESS {
                iterators.append(iterator)
                while case let object = IOIteratorNext(iterator), object != 0 { IOObjectRelease(object) }
            } else {
                if iterator != 0 { IOObjectRelease(iterator) }
                startFallback()
            }
        }
    }
    private func startFallback() {
        guard fallbackTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 10, repeating: .seconds(10), leeway: .seconds(3))
        timer.setEventHandler { [weak self] in self?.onChange?() }
        fallbackTimer = timer
        timer.resume()
    }
    deinit {
        fallbackTimer?.cancel()
        for iterator in iterators { IOObjectRelease(iterator) }
        if let port { IONotificationPortDestroy(port) }
    }
}
