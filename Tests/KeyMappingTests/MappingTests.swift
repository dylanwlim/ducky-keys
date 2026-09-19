import Foundation
import Testing
@testable import KeyMapping

final class MappingTests {
    private let extra = KeyMap(0x700000039, 0x700000029)
    private let later = KeyMap(0x70000003A, 0x70000003B)

    private func keyboard(id: String = "ducky", name: String = "Ducky One X", vendor: Int = 0x3233, product: Int = 0x0018, transport: String = "USB", builtIn: Bool = false, isKeyboard: Bool = true) -> Keyboard {
        Keyboard(id: id, name: name, vendor: vendor, product: product, transport: transport, builtIn: builtIn, isKeyboard: isKeyboard)
    }

    @Test func testRecognizesConfiguredPairAndDuckyBluetoothName() {
        #expect(keyboard(name: "Wireless Keyboard").isDucky(savedNames: []))
        #expect(keyboard(name: "DUCKY One X", vendor: 7, product: 8, transport: "Bluetooth Low Energy").isDucky(savedNames: []))
        #expect(keyboard(name: "Office board", vendor: 7, product: 8, transport: "Bluetooth").isDucky(savedNames: ["office BOARD"]))
        #expect(!(keyboard(name: "Office board", vendor: 7, product: 8, transport: "USB").isDucky(savedNames: ["Office board"])))
    }

    @Test func testRejectsBuiltInVirtualNonKeyboardAndSharedVendor() {
        let excluded = [
            keyboard(builtIn: true),
            keyboard(isKeyboard: false),
            keyboard(vendor: 0x05ac),
            keyboard(name: "Ducky Virtual Keyboard"),
            keyboard(name: "Karabiner Ducky Keyboard"),
            keyboard(name: "NotDucky", vendor: 9, product: 8),
            keyboard(name: "Unrelated keyboard", product: 0x0199),
            keyboard(name: "Unrelated keyboard", vendor: 9, product: 8)
        ]
        for device in excluded { #expect(!(device.isDucky(savedNames: [device.name])), Comment(rawValue: device.name)) }
    }

    @Test func testSwapReplacesOnlyLeftControlAndLeftCommand() {
        let right = KeyMap(0x7000000E4, 0x7000000E7)
        let original = [extra, KeyMap(KeyMap.control, 9), KeyMap(KeyMap.command, 10), right]
        let result = KeyMap.applying(to: original)
        #expect(KeyMap.equivalent(result, [extra, right] + KeyMap.swap))
        #expect(KeyMap.swap == [KeyMap(0x7000000E0, 0x7000000E3), KeyMap(0x7000000E3, 0x7000000E0)])
        #expect(KeyMap.applying(to: result) == result)
    }

    @Test func testEquivalentIgnoresOrderButNotDestination() {
        #expect(KeyMap.equivalent(KeyMap.swap, KeyMap.swap.reversed()))
        #expect(!(KeyMap.equivalent(KeyMap.swap, [KeyMap(KeyMap.control, KeyMap.control), KeyMap.swap[1]])))
    }

    @Test func testDisabledStartupDoesNotWriteAnyDevice() {
        let backend = FakeBackend(devices: [keyboard()])
        let engine = MappingEngine(backend: backend)
        engine.reconcile(enabled: false, savedNames: [])
        #expect(backend.writes.isEmpty)
        #expect(engine.owned.isEmpty)
        #expect(engine.connected.count == 1)
    }

    @Test func testEnablingChangesOnlyDuckyAndIsIdempotent() {
        let other = keyboard(id: "other", name: "Other keyboard", vendor: 9, product: 10)
        let internalDevice = keyboard(id: "internal", builtIn: true)
        let backend = FakeBackend(devices: [keyboard(), other, internalDevice])
        backend.maps["ducky"] = [extra]
        let engine = MappingEngine(backend: backend)
        engine.reconcile(enabled: true, savedNames: [])
        engine.reconcile(enabled: true, savedNames: [])
        #expect(backend.writes.map(\.id) == ["ducky"])
        #expect(KeyMap.equivalent(backend.maps["ducky"]!, [extra] + KeyMap.swap))
        #expect(backend.maps["other"] == [])
        #expect(backend.maps["internal"] == [])
        #expect(engine.connected.map(\.id) == ["ducky"])
        #expect(engine.failures.isEmpty)
    }

    @Test func testDisableRestoresOriginalControlledKeysAndKeepsLaterUnrelatedEdits() {
        let backend = FakeBackend(devices: [keyboard()])
        let oldControl = KeyMap(KeyMap.control, 0x7000000E2)
        backend.maps["ducky"] = [extra, oldControl]
        let engine = MappingEngine(backend: backend)
        engine.reconcile(enabled: true, savedNames: [])
        backend.maps["ducky"] = [later] + KeyMap.swap
        engine.reconcile(enabled: false, savedNames: [])
        #expect(KeyMap.equivalent(backend.maps["ducky"]!, [later, oldControl]))
        #expect(engine.owned.isEmpty)
        #expect(engine.failures.isEmpty)
    }

    @Test func testDisableDoesNotOverwriteAnotherToolsControlledKeys() {
        let backend = FakeBackend(devices: [keyboard()])
        let engine = MappingEngine(backend: backend)
        engine.reconcile(enabled: true, savedNames: [])
        let external = [KeyMap(KeyMap.control, 0x7000000E2), later]
        backend.maps["ducky"] = external
        engine.reconcile(enabled: false, savedNames: [])
        #expect(backend.maps["ducky"] == external)
        #expect(backend.writes.count == 1)
        #expect(engine.failures == ["Ducky One X"])
    }

    @Test func testUnrelatedLaterEditsWhileEnabledRemainActiveWithoutExtraWrites() {
        let backend = FakeBackend(devices: [keyboard()])
        let engine = MappingEngine(backend: backend)
        engine.reconcile(enabled: true, savedNames: [])
        backend.maps["ducky"] = [later] + KeyMap.swap
        engine.reconcile(enabled: true, savedNames: [])
        #expect(engine.failures.isEmpty)
        #expect(backend.writes.count == 1)
        engine.reconcile(enabled: false, savedNames: [])
        #expect(backend.maps["ducky"] == [later])
    }

    @Test func testReadFailureDoesNotWriteOrInventAnOriginalMapping() {
        let backend = FakeBackend(devices: [keyboard()])
        backend.unreadable.insert("ducky")
        let engine = MappingEngine(backend: backend)
        engine.reconcile(enabled: true, savedNames: [])
        #expect(backend.writes.isEmpty)
        #expect(engine.owned.isEmpty)
        #expect(engine.failures == ["Ducky One X"])
    }

    @Test func testFailedWriteIsReportedAndRetriesWithoutLosingOriginal() {
        let backend = FakeBackend(devices: [keyboard()])
        backend.maps["ducky"] = [extra]
        backend.writeSucceeds = false
        let engine = MappingEngine(backend: backend)
        engine.reconcile(enabled: true, savedNames: [])
        #expect(engine.failures == ["Ducky One X"])
        #expect(engine.owned["ducky"]?.original == [extra])
        #expect(backend.maps["ducky"] == [extra])
        backend.writeSucceeds = true
        engine.reconcile(enabled: true, savedNames: [])
        #expect(engine.failures.isEmpty)
        #expect(backend.writes.count == 2)
        engine.reconcile(enabled: false, savedNames: [])
        #expect(backend.maps["ducky"] == [extra])
    }

    @Test func testReadbackMismatchCannotReportSuccess() {
        let backend = FakeBackend(devices: [keyboard()])
        backend.ignoreWrites = true
        let engine = MappingEngine(backend: backend)
        engine.reconcile(enabled: true, savedNames: [])
        #expect(engine.failures == ["Ducky One X"])
        #expect(engine.owned["ducky"] != nil)
        #expect(backend.maps["ducky"] == [])
    }

    @Test func testUnreadableReadbackRetainsJournalForLaterRestore() {
        let backend = FakeBackend(devices: [keyboard()])
        backend.afterWrite = { backend.unreadable.insert($0) }
        let engine = MappingEngine(backend: backend)
        engine.reconcile(enabled: true, savedNames: [])
        #expect(engine.failures == ["Ducky One X"])
        #expect(engine.owned["ducky"] != nil)
        backend.unreadable = []
        backend.afterWrite = nil
        engine.reconcile(enabled: false, savedNames: [])
        #expect(backend.maps["ducky"] == [])
        #expect(engine.owned.isEmpty)
    }

    @Test func testFailedRestoreRetainsOwnershipUntilSuccessfulRetry() {
        let backend = FakeBackend(devices: [keyboard()])
        let engine = MappingEngine(backend: backend)
        engine.reconcile(enabled: true, savedNames: [])
        backend.writeSucceeds = false
        engine.reconcile(enabled: false, savedNames: [])
        #expect(engine.owned["ducky"] != nil)
        #expect(engine.failures == ["Ducky One X"])
        backend.writeSucceeds = true
        engine.reconcile(enabled: false, savedNames: [])
        #expect(engine.owned.isEmpty)
        #expect(engine.failures.isEmpty)
    }

    @Test func testJournalIsSavedBeforeFirstWriteAndSurvivesRelaunch() throws {
        let backend = FakeBackend(devices: [keyboard()])
        backend.maps["ducky"] = [extra]
        let first = MappingEngine(backend: backend)
        var saved: [String: OwnedMapping] = [:]
        first.save = { saved = $0 }
        backend.beforeWrite = { _ in
            #expect(saved["ducky"]?.original == [self.extra])
            #expect(backend.maps["ducky"] == [self.extra])
        }
        first.reconcile(enabled: true, savedNames: [])
        backend.beforeWrite = nil
        let encoded = try JSONEncoder().encode(saved)
        let journal = try JSONDecoder().decode([String: OwnedMapping].self, from: encoded)
        let relaunched = MappingEngine(backend: backend, owned: journal)
        relaunched.reconcile(enabled: true, savedNames: [])
        #expect(backend.writes.count == 1)
        relaunched.reconcile(enabled: false, savedNames: [])
        #expect(backend.maps["ducky"] == [extra])
        #expect(relaunched.owned.isEmpty)
    }

    @Test func testJournalWrittenBeforeCrashButBeforeMutationIsSafeToDisable() {
        let backend = FakeBackend(devices: [keyboard()])
        backend.maps["ducky"] = [extra]
        let pending = OwnedMapping(fingerprint: keyboard().fingerprint, original: [extra], applied: [extra] + KeyMap.swap)
        let engine = MappingEngine(backend: backend, owned: ["ducky": pending])
        engine.reconcile(enabled: false, savedNames: [])
        #expect(backend.writes.isEmpty)
        #expect(engine.owned.isEmpty)
        #expect(engine.failures.isEmpty)
    }

    @Test func testDisconnectedServiceIsDroppedAndNewConnectionGetsFreshBaseline() {
        let backend = FakeBackend(devices: [keyboard()])
        backend.maps["ducky"] = [extra]
        let engine = MappingEngine(backend: backend)
        engine.reconcile(enabled: true, savedNames: [])
        backend.devices = []
        engine.reconcile(enabled: true, savedNames: [])
        #expect(engine.owned.isEmpty)
        #expect(engine.connected.isEmpty)
        backend.devices = [keyboard(id: "reconnected", transport: "Bluetooth")]
        backend.maps["reconnected"] = [later]
        engine.reconcile(enabled: true, savedNames: [])
        #expect(engine.owned["reconnected"]?.original == [later])
        #expect(backend.writes.map(\.id) == ["ducky", "reconnected"])
        engine.reconcile(enabled: false, savedNames: [])
        #expect(backend.maps["reconnected"] == [later])
    }

    @Test func testReusedRegistryIdentifierDoesNotRestoreOntoDifferentKeyboard() {
        let backend = FakeBackend(devices: [keyboard()])
        let engine = MappingEngine(backend: backend)
        engine.reconcile(enabled: true, savedNames: [])
        backend.devices = [keyboard(name: "Different keyboard", vendor: 100, product: 200)]
        backend.maps["ducky"] = [later]
        engine.reconcile(enabled: false, savedNames: [])
        #expect(backend.maps["ducky"] == [later])
        #expect(backend.writes.count == 1)
        #expect(engine.owned.isEmpty)
    }

    @Test func testMappingResetWhileConnectedIsReapplied() {
        let backend = FakeBackend(devices: [keyboard()])
        let engine = MappingEngine(backend: backend)
        engine.reconcile(enabled: true, savedNames: [])
        backend.maps["ducky"] = []
        engine.reconcile(enabled: true, savedNames: [])
        #expect(KeyMap.equivalent(backend.maps["ducky"]!, KeyMap.swap))
        #expect(backend.writes.count == 2)
        #expect(engine.failures.isEmpty)
    }

    @Test func testEnumerationFailurePreservesOwnershipAndDoesNotSaveAnEmptyJournal() {
        let backend = FakeBackend(devices: [keyboard()])
        backend.maps["ducky"] = [extra]
        let engine = MappingEngine(backend: backend)
        engine.reconcile(enabled: true, savedNames: [])
        var saves = 0
        engine.save = { _ in saves += 1 }
        backend.enumerationSucceeds = false
        engine.reconcile(enabled: true, savedNames: [])
        #expect(engine.owned["ducky"]?.original == [extra])
        #expect(engine.connected.map(\.id) == ["ducky"])
        #expect(!engine.failures.isEmpty)
        #expect(backend.writes.count == 1)
        #expect(saves == 0)
        backend.enumerationSucceeds = true
        engine.reconcile(enabled: true, savedNames: [])
        #expect(engine.failures.isEmpty)
        #expect(backend.writes.count == 1)
        engine.reconcile(enabled: false, savedNames: [])
        #expect(backend.maps["ducky"] == [extra])
    }

    @Test func testFailedStartupEnumerationKeepsCrashJournalForRestore() {
        let backend = FakeBackend(devices: [keyboard()])
        backend.maps["ducky"] = [extra] + KeyMap.swap
        backend.enumerationSucceeds = false
        let entry = OwnedMapping(fingerprint: keyboard().fingerprint, original: [extra], applied: [extra] + KeyMap.swap)
        let engine = MappingEngine(backend: backend, owned: ["ducky": entry])
        engine.reconcile(enabled: false, savedNames: [])
        #expect(engine.owned["ducky"]?.original == [extra])
        #expect(backend.writes.isEmpty)
        #expect(!engine.failures.isEmpty)
        backend.enumerationSucceeds = true
        engine.reconcile(enabled: false, savedNames: [])
        #expect(engine.owned.isEmpty)
        #expect(engine.failures.isEmpty)
        #expect(backend.maps["ducky"] == [extra])
    }
}

private final class FakeBackend: MappingBackend {
    struct Write { let id: String; let maps: [KeyMap] }
    var devices: [Keyboard]
    var maps: [String: [KeyMap]]
    var writes: [Write] = []
    var unreadable: Set<String> = []
    var writeSucceeds = true
    var ignoreWrites = false
    var enumerationSucceeds = true
    var beforeWrite: ((String) -> Void)?
    var afterWrite: ((String) -> Void)?
    init(devices: [Keyboard]) {
        self.devices = devices
        maps = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, []) })
    }
    func keyboards() -> [Keyboard]? { enumerationSucceeds ? devices : nil }
    func read(_ id: String) -> [KeyMap]? { unreadable.contains(id) ? nil : maps[id] }
    func write(_ id: String, maps value: [KeyMap]) -> Bool {
        beforeWrite?(id)
        writes.append(Write(id: id, maps: value))
        guard writeSucceeds else { return false }
        if !ignoreWrites { maps[id] = value }
        afterWrite?(id)
        return true
    }
}
