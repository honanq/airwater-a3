import Combine
import Foundation
import Security

/// Separate from DeviceCredential: the MQTT device key is not a Wi-Fi password.
struct HotspotCredential: Codable, Equatable {
    let ssid: String
    let password: String
}

protocol HotspotCredentialPersistence {
    func load() throws -> HotspotCredential?
    func save(_ credential: HotspotCredential) throws
    func delete() throws
}

struct KeychainHotspotCredentialStore: HotspotCredentialPersistence {
    // Keep this namespace stable across releases; never reuse the device-key item.
    private let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.sudohg.airwaterprobe.hotspot",
        kSecAttrAccount as String: "personal-hotspot",
        kSecAttrSynchronizable as String: false
    ]

    func load() throws -> HotspotCredential? {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecDecode))
        }
        return try JSONDecoder().decode(HotspotCredential.self, from: data)
    }

    func save(_ credential: HotspotCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let values: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        // Update in place. Deleting before adding could destroy the last good item
        // if a locked keychain, entitlement error or interrupted write follows.
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            values.forEach { attributes[$0.key] = $0.value }
            status = SecItemAdd(attributes as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
            }
        }
        try check(status)
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            // Only a numeric status; never put credentials into an error or log.
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}

@MainActor
final class HotspotSettings: ObservableObject {
    @Published var name = "" {
        didSet { if !isRestoring { hasEdited = true } }
    }
    @Published var password = "" {
        didSet { if !isRestoring { hasEdited = true } }
    }
    @Published private(set) var storageStatus = ""
    @Published private(set) var hasSavedCredentials = false
    @Published private(set) var canRetrySave = false

    private let store: HotspotCredentialPersistence
    private var didRestore = false
    private var isRestoring = false
    private var hasEdited = false
    private var acceptedCredentialToSave: HotspotCredential?

    init(store: HotspotCredentialPersistence = KeychainHotspotCredentialStore()) {
        self.store = store
    }

    func restoreIfNeeded() {
        // A view reappearance/foreground event must not replace an edited draft.
        guard !didRestore, !hasEdited else { return }
        isRestoring = true
        defer { isRestoring = false }
        do {
            if let credential = try store.load() {
                name = credential.ssid
                password = credential.password
                hasSavedCredentials = true
                storageStatus = "已从本机钥匙串恢复热点配置。"
            } else {
                hasSavedCredentials = false
                storageStatus = ""
            }
            didRestore = true
        } catch {
            // Locked/unavailable/corrupt is NOT 'not found'. Keep the item intact
            // and allow a later foreground event to retry, without logging data.
            storageStatus = "暂时无法读取已保存配置；解锁后返回 App 可重试，未删除原记录。"
        }
    }

    /// Called at the successful cmd21 acknowledgement, not when Send is tapped
    /// and not after the optional cmd22 device-ID query.
    func rememberAccepted(_ credential: HotspotCredential) {
        didRestore = true
        acceptedCredentialToSave = credential
        retrySave()
    }

    func retrySave() {
        guard let credential = acceptedCredentialToSave else { return }
        do {
            try store.save(credential)
            acceptedCredentialToSave = nil
            canRetrySave = false
            hasSavedCredentials = true
            storageStatus = "设备已接受配置，已安全保存在本机；下次会自动填入。"
        } catch {
            canRetrySave = true
            storageStatus = "设备已接受配置，但本机保存失败；输入仍保留，请解锁后点重试保存。"
        }
    }

    func forget() {
        do {
            try store.delete()
            acceptedCredentialToSave = nil
            canRetrySave = false
            hasSavedCredentials = false
            didRestore = true
            name = ""
            password = ""
            storageStatus = "已删除本机保存的热点配置；未修改系统热点或加湿器。"
        } catch {
            storageStatus = "删除失败，原记录和当前输入均已保留；请解锁后重试。"
        }
    }
}
