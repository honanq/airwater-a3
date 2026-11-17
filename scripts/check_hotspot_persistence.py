#!/usr/bin/env python3
"""Bounded source-contract checks; NOT a Swift build, Keychain or BLE runtime test."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
STORE = (ROOT / "Sources/HotspotCredentials.swift").read_text()
BLE = (ROOT / "Sources/A3Bluetooth.swift").read_text()
VIEW = (ROOT / "Sources/ConnectionView.swift").read_text()


def between(text, start, end):
    return text.split(start, 1)[1].split(end, 1)[0]


class HotspotSourceContracts(unittest.TestCase):
    def test_separate_keychain_namespace(self):
        self.assertIn('"com.sudohg.airwaterprobe.hotspot"', STORE)
        self.assertNotIn('"com.sudohg.airwaterprobe.device"', STORE)

    def test_local_unlocked_non_sync_item(self):
        self.assertIn('kSecAttrSynchronizable as String: false', STORE)
        self.assertIn('kSecAttrAccessibleWhenUnlockedThisDeviceOnly', STORE)

    def test_read_only_notfound_is_empty(self):
        load = between(STORE, '    func load() throws -> HotspotCredential? {', '    func save(')
        self.assertIn('if status == errSecItemNotFound { return nil }', load)
        self.assertIn('try check(status)', load)
        self.assertIn('try JSONDecoder().decode', load)
        self.assertNotIn('try?', load)
        self.assertNotIn('SecItemDelete', load)

    def test_update_without_delete_before_add(self):
        save = between(STORE, '    func save(_ credential: HotspotCredential) throws {', '    func delete() throws {')
        self.assertLess(save.index('SecItemUpdate'), save.index('SecItemAdd'))
        self.assertIn('if status == errSecItemNotFound', save)
        self.assertIn('if status == errSecDuplicateItem', save)
        self.assertNotIn('SecItemDelete', save)

    def test_delete_is_explicit_and_narrow(self):
        self.assertEqual(STORE.count('SecItemDelete('), 1)
        self.assertIn('SecItemDelete(query as CFDictionary)', STORE)
        self.assertIn('if status != errSecItemNotFound { try check(status) }', STORE)

    def test_no_plaintext_defaults_or_logging(self):
        self.assertNotIn('UserDefaults', STORE)
        self.assertNotIn('@AppStorage', STORE)
        self.assertNotRegex(STORE, r'\b(?:print|NSLog|debugPrint)\s*\(')
        self.assertNotIn('localizedDescription', STORE)
        self.assertNotIn('write(to:', STORE)

    def test_root_lifetime_model(self):
        self.assertIn('@StateObject private var hotspot = HotspotSettings()', VIEW)
        self.assertNotIn('@State private var hotspotName', VIEW)
        self.assertNotIn('@State private var hotspotPassword', VIEW)
        self.assertIn('@ObservedObject var hotspot: HotspotSettings', VIEW)

    def test_secure_field_and_no_send_clear(self):
        self.assertIn('SecureField("个人热点的 Wi-Fi 密码", text: $hotspot.password)', VIEW)
        self.assertNotRegex(VIEW, r'(?:hotspotPassword|hotspot\.password)\s*=\s*""')
        self.assertNotIn('发送后清空密码', VIEW)

    def test_root_ack_callback_has_no_self_cycle(self):
        root = VIEW.split('// MARK: - Derived state', 1)[0]
        self.assertIn('bluetooth.onProvisionAccepted = { [hotspot] credential in', root)
        self.assertIn('hotspot.rememberAccepted(credential)', root)

    def test_foreground_retries_restore(self):
        active = between(VIEW, 'if phase == .active {', '.onOpenURL')
        self.assertIn('hotspot.restoreIfNeeded()', active)
        appear = between(VIEW, '        .onAppear {', '// MARK: - Derived state')
        self.assertLess(appear.index('hotspot.restoreIfNeeded()'), appear.index('guard !didAutostart'))

    def test_edited_then_empty_draft_not_reloaded(self):
        self.assertEqual(STORE.count('didSet { if !isRestoring { hasEdited = true } }'), 2)
        restore = between(STORE, '    func restoreIfNeeded() {', '    /// Called at')
        self.assertIn('guard !didRestore, !hasEdited else { return }', restore)
        self.assertIn('defer { isRestoring = false }', restore)
        self.assertNotIn('store.delete', restore)

    def test_snapshot_after_validation(self):
        provision = between(BLE, '    func provision(ssid:', '    private func beginScan()')
        snapshot = provision.index('pendingHotspotCredential = HotspotCredential(')
        self.assertLess(provision.index('guard canProvision'), snapshot)
        self.assertLess(provision.index('guard (1...32).contains(ssidBytes.count)'), snapshot)
        self.assertLess(provision.index('guard (8...63).contains(passwordBytes.count)'), snapshot)
        self.assertLess(snapshot, provision.index('sendRequest(command: 21'))
        self.assertNotIn('onProvisionAccepted?', provision)

    def test_save_only_on_success_ack_before_id_query(self):
        response = between(BLE, '    private func handleResponse(', '    private func validHandshakeReply(')
        ack = between(response, '        case 21:', '        case 22:')
        self.assertLess(ack.index('guard result == 1'), ack.index('onProvisionAccepted?(credential)'))
        self.assertLess(ack.index('pendingHotspotCredential = nil'), ack.index('onProvisionAccepted?(credential)'))
        self.assertLess(ack.index('onProvisionAccepted?(credential)'), ack.index('queryDeviceID()'))
        self.assertEqual(BLE.count('onProvisionAccepted?('), 1)

    def test_reset_releases_only_pending_memory(self):
        reset = between(BLE, '    private func resetRequestState()', '    private func clearPendingWrites()')
        self.assertIn('pendingHotspotCredential = nil', reset)
        self.assertNotIn('Keychain', reset)
        self.assertNotIn('SecItem', BLE)
        self.assertNotIn('store.delete', BLE)

    def test_save_retry_uses_accepted_snapshot(self):
        retry = between(STORE, '    func retrySave() {', '    func forget() {')
        self.assertIn('guard let credential = acceptedCredentialToSave', retry)
        self.assertIn('try store.save(credential)', retry)
        self.assertNotIn('HotspotCredential(ssid: name', retry)
        self.assertNotIn('bluetooth', retry)
        self.assertLess(retry.index('try store.save(credential)'), retry.index('acceptedCredentialToSave = nil'))
        self.assertIn('canRetrySave = true', retry)

    def test_forget_cannot_race_inflight_ack(self):
        self.assertIn('bluetooth.state == .provisioning || bluetooth.state == .queryingDeviceID', VIEW)
        self.assertIn('guard !provisioningInFlight else { return }', VIEW)
        self.assertIn('.disabled(provisioningInFlight)', VIEW)
        self.assertIn('.confirmationDialog(', VIEW)

    def test_failed_forget_preserves_state(self):
        forget = STORE.split('    func forget() {', 1)[1]
        self.assertLess(forget.index('try store.delete()'), forget.index('acceptedCredentialToSave = nil'))
        catch = forget.split('        } catch {', 1)[1]
        self.assertNotIn('password = ""', catch)
        self.assertNotIn('acceptedCredentialToSave = nil', catch)

    def test_no_automatic_provisioning_added(self):
        calls = sum(p.read_text().count('bluetooth.provision(') for p in (ROOT / 'Sources').glob('*.swift'))
        self.assertEqual(calls, 1)
        self.assertEqual(BLE.count('sendRequest(command: 21'), 1)
        self.assertNotIn('provision(', STORE)


if __name__ == '__main__':
    unittest.main(verbosity=2)
