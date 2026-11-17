// Run on macOS; see docs/HOTSPOT-PERSISTENCE.md. No real keychain or A3 access.
import Foundation

private final class MemoryHotspotStore: HotspotCredentialPersistence {
    var value: HotspotCredential?
    var failLoad = false
    var failSave = false
    var failDelete = false
    var loads = 0
    var saves = 0
    var deletes = 0
    private let failure = NSError(domain: "SyntheticStorageFailure", code: 1)

    func load() throws -> HotspotCredential? {
        loads += 1
        if failLoad { throw failure }
        return value
    }
    func save(_ credential: HotspotCredential) throws {
        saves += 1
        if failSave { throw failure }
        value = credential
    }
    func delete() throws {
        deletes += 1
        if failDelete { throw failure }
        value = nil
    }
}

@main
private struct HotspotSettingsChecks {
    @MainActor static func main() {
        var count = 0
        var failed = 0
        func check(_ passed: Bool, _ name: String) {
            count += 1
            if !passed { failed += 1; print("FAIL: \(name)") }
        }
        let first = HotspotCredential(ssid: "fixture-hotspot-a", password: "fixture-password-a")
        let second = HotspotCredential(ssid: "fixture-hotspot-b", password: "fixture-password-b")
        let store = MemoryHotspotStore()
        store.value = first
        let settings = HotspotSettings(store: store)
        settings.restoreIfNeeded()
        check(settings.name == first.ssid && settings.password == first.password, "restore both fields")
        check(settings.hasSavedCredentials, "restored item is marked saved")
        settings.restoreIfNeeded()
        check(store.loads == 1, "reappearance loads only once")
        check(store.saves == 0 && store.deletes == 0, "restoring does not mutate storage")

        let emptyStore = MemoryHotspotStore()
        let empty = HotspotSettings(store: emptyStore)
        empty.restoreIfNeeded()
        empty.restoreIfNeeded()
        check(empty.name.isEmpty && empty.password.isEmpty, "first install remains empty")
        check(!empty.hasSavedCredentials && emptyStore.loads == 1, "not found is a completed read")

        let lockedStore = MemoryHotspotStore()
        lockedStore.value = first
        lockedStore.failLoad = true
        let locked = HotspotSettings(store: lockedStore)
        locked.restoreIfNeeded()
        check(locked.name.isEmpty && !locked.storageStatus.isEmpty, "read failure is visible")
        check(lockedStore.value == first && lockedStore.deletes == 0, "read failure preserves item")
        lockedStore.failLoad = false
        locked.restoreIfNeeded()
        check(locked.password == first.password && lockedStore.loads == 2, "unlocked read retries")

        let missingAfterLockStore = MemoryHotspotStore()
        missingAfterLockStore.failLoad = true
        let missingAfterLock = HotspotSettings(store: missingAfterLockStore)
        missingAfterLock.restoreIfNeeded()
        missingAfterLockStore.failLoad = false
        missingAfterLock.restoreIfNeeded()
        check(missingAfterLock.storageStatus.isEmpty && !missingAfterLock.hasSavedCredentials,
              "successful not-found retry clears stale read error")

        let draftStore = MemoryHotspotStore()
        draftStore.value = first
        draftStore.failLoad = true
        let draft = HotspotSettings(store: draftStore)
        draft.restoreIfNeeded()
        draft.name = second.ssid
        draft.password = second.password
        draftStore.failLoad = false
        draft.restoreIfNeeded()
        check(draft.name == second.ssid && draft.password == second.password, "foreground preserves draft")
        draft.name = ""
        draft.password = ""
        draft.restoreIfNeeded()
        check(draft.name.isEmpty && draft.password.isEmpty, "clearing an edited draft stays empty")
        check(draftStore.loads == 1, "edited draft blocks automatic reload")

        settings.name = second.ssid
        settings.password = second.password
        settings.rememberAccepted(first)
        check(store.value == first, "save the sent snapshot, not later edits")
        check(settings.name == second.ssid && settings.password == second.password, "acknowledgement preserves edits")
        check(settings.hasSavedCredentials && !settings.canRetrySave, "save success is visible")
        let saves = store.saves
        settings.retrySave()
        check(store.saves == saves, "successful save consumes pending snapshot")

        store.failSave = true
        settings.rememberAccepted(second)
        check(store.value == first, "failed save does not delete prior good item")
        check(settings.canRetrySave, "failed save can retry")
        check(settings.password == second.password, "failed save does not clear password")
        settings.name = "new-unsent-draft"
        settings.password = "new-unsent-password"
        store.failSave = false
        settings.retrySave()
        check(store.value == second, "retry saves accepted snapshot, not unsent draft")
        check(!settings.canRetrySave, "successful retry clears retry state")
        let relaunched = HotspotSettings(store: store)
        relaunched.restoreIfNeeded()
        check(relaunched.name == second.ssid && relaunched.password == second.password, "new instance restores saved configuration")

        store.failDelete = true
        settings.forget()
        check(store.value == second, "delete failure preserves saved record")
        check(settings.password == "new-unsent-password", "delete failure preserves draft")
        check(settings.hasSavedCredentials, "delete failure does not claim success")
        store.failDelete = false
        settings.forget()
        check(store.value == nil, "explicit forget deletes saved record")
        check(settings.name.isEmpty && settings.password.isEmpty, "forget clears fields")
        check(!settings.hasSavedCredentials && !settings.canRetrySave, "forget clears saved and retry state")
        settings.restoreIfNeeded()
        settings.retrySave()
        check(store.value == nil && settings.password.isEmpty, "foreground and retry cannot undo forget")

        let pendingStore = MemoryHotspotStore()
        pendingStore.failSave = true
        let pending = HotspotSettings(store: pendingStore)
        pending.rememberAccepted(first)
        check(pending.canRetrySave, "pending snapshot exists after failed save")
        pendingStore.failDelete = true
        pending.forget()
        check(pending.canRetrySave, "failed forget retains pending snapshot")
        pendingStore.failDelete = false
        pending.forget()
        pendingStore.failSave = false
        pending.retrySave()
        check(pendingStore.value == nil && !pending.canRetrySave, "successful forget invalidates failed-save snapshot")
        check(pendingStore.saves == 1, "forgotten snapshot is not written again")

        // Round-trip only synthetic fixtures; no passwords are printed.
        let encoded = try! JSONEncoder().encode(second)
        let decoded = try! JSONDecoder().decode(HotspotCredential.self, from: encoded)
        check(decoded == second, "credential encoding round-trip")
        check(!settings.storageStatus.contains(first.password)
              && !settings.storageStatus.contains(second.password), "status never includes fixture passwords")
        print("\(count) hotspot model checks, \(failed) failures; in-memory store only.")
        if failed != 0 { exit(1) }
    }
}
