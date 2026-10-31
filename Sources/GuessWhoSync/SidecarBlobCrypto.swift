import Foundation
import CryptoKit
import Logging

#if canImport(Security)
import Security
#endif

// Encryption seam for `.blob` `.dat` payloads.
//
// A `.dat` lives under the same iCloud ubiquity root as its envelope and so
// syncs to every one of the user's devices. We encrypt the payload at rest
// with AES-GCM (CryptoKit) under a 256-bit symmetric key kept in the
// iCloud-SYNCHRONIZABLE keychain, so every device that receives the synced
// `.dat` can also decrypt it.
//
// The protocol is injectable so unit tests pass a deterministic in-memory key
// (`InMemoryBlobCrypto`) and never touch the real keychain; production uses the
// keychain-backed `KeychainBlobCrypto`.
@_spi(ConflictReconcile)
public protocol SidecarBlobCrypto: AnyObject {
    // Encrypt `plaintext`, returning the AES-GCM sealed box's `combined`
    // representation (nonce || ciphertext || tag) ready to write to disk.
    func encrypt(_ plaintext: Data) throws -> Data
    // Decrypt a `combined` AES-GCM sealed box produced by `encrypt`.
    func decrypt(_ ciphertext: Data) throws -> Data
}

@_spi(ConflictReconcile)
public enum SidecarBlobCryptoError: LocalizedError, Equatable {
    // The keychain returned an unexpected OSStatus we don't map to a
    // recoverable case (duplicate-item is handled internally via re-read).
    case keychainStatus(Int32)
    // The keychain held an item but its bytes weren't a valid 256-bit key.
    case malformedKey
    // No keychain is available on this platform (non-Apple SwiftPM CI). The
    // store can't produce a synced key, so blob I/O is unsupported there.
    case keychainUnavailable

    // Shown in the photo alerts and written to the logs. Only photos use blob
    // storage today, so this speaks about photos and keeps the OSStatus visible.
    public var errorDescription: String? {
        switch self {
        case .keychainStatus(let status):
            return "The keychain wouldn’t provide the key that protects your photos (error \(status))."
        case .malformedKey:
            return "The key that protects your photos isn’t usable."
        case .keychainUnavailable:
            return "This device has no keychain to protect your photos."
        }
    }
}

#if !canImport(Security)
// Fallback used only where Security (and thus the keychain) is unavailable —
// e.g. linux SwiftPM CI. Blob I/O is an Apple-platform feature; calling it
// here throws rather than silently writing unencrypted bytes.
final class UnavailableBlobCrypto: SidecarBlobCrypto {
    func encrypt(_ plaintext: Data) throws -> Data {
        throw SidecarBlobCryptoError.keychainUnavailable
    }
    func decrypt(_ ciphertext: Data) throws -> Data {
        throw SidecarBlobCryptoError.keychainUnavailable
    }
}
#endif

// MARK: - In-memory (tests)

/// A crypto seam backed by a caller-supplied symmetric key held only in
/// memory. Used by unit tests so encryption is exercised end-to-end WITHOUT
/// ever reading or writing the real (synchronizable) keychain. Default init
/// mints a random key per instance; pass `key:` for determinism across two
/// "devices" in a single test.
@_spi(ConflictReconcile)
public final class InMemoryBlobCrypto: SidecarBlobCrypto {
    private let key: SymmetricKey

    public init(key: SymmetricKey = SymmetricKey(size: .bits256)) {
        self.key = key
    }

    public func encrypt(_ plaintext: Data) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            // `combined` is non-nil for the default 12-byte nonce, which we use.
            throw SidecarBlobCryptoError.malformedKey
        }
        return combined
    }

    public func decrypt(_ ciphertext: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: key)
    }
}

// MARK: - Keychain (production)

#if canImport(Security)
/// Production crypto seam. Loads (or, on first use, mints) the 256-bit key from
/// the iCloud-synchronizable keychain and encrypts/decrypts with AES-GCM.
///
/// Key attributes:
///  - `kSecAttrSynchronizable = kCFBooleanTrue` so the key syncs to the user's
///    other devices (each device must decrypt the synced `.dat`).
///  - `kSecAttrAccessibleAfterFirstUnlock` — a synchronizable item CANNOT be
///    `…ThisDeviceOnly` (the OS rejects it), so we use the device-agnostic
///    after-first-unlock class.
///
/// The key is loaded lazily and cached for the instance lifetime.
@_spi(ConflictReconcile)
public final class KeychainBlobCrypto: SidecarBlobCrypto {
    private static let log = Logger(label: "sync.blob-crypto")

    private let service: String
    private let account: String
    private let lock = NSLock()
    private var cachedKey: SymmetricKey?

    public static let defaultService = "com.milestonemade.guesswho.sidecar-blob"
    public static let defaultAccount = "v1"

    public init(
        service: String = KeychainBlobCrypto.defaultService,
        account: String = KeychainBlobCrypto.defaultAccount
    ) {
        self.service = service
        self.account = account
    }

    public func encrypt(_ plaintext: Data) throws -> Data {
        let key = try loadOrCreateKey()
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            throw SidecarBlobCryptoError.malformedKey
        }
        return combined
    }

    public func decrypt(_ ciphertext: Data) throws -> Data {
        let key = try loadOrCreateKey()
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: key)
    }

    // Read the synced key; if absent, mint a fresh one, store it, and return
    // it. Handles the cross-device race where two devices both mint before
    // either's keychain syncs: on a `errSecDuplicateItem` add, re-read the
    // now-present item (the sync layer resolves which copy survives).
    func loadOrCreateKey() throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let cachedKey { return cachedKey }

        if let existing = try readKey() {
            cachedKey = existing
            logKeyReady(existing, source: "keychain")
            return existing
        }

        let fresh = SymmetricKey(size: .bits256)
        let freshData = fresh.withUnsafeBytes { Data($0) }
        let status = addKey(freshData)
        switch status {
        case errSecSuccess:
            cachedKey = fresh
            logKeyReady(fresh, source: "minted")
            return fresh
        case errSecDuplicateItem:
            // Another device (or a racing call) added one first; re-read it so
            // every caller converges on the same key bytes.
            guard let raced = try readKey() else {
                logFailure("add-then-read", status: errSecDuplicateItem)
                throw SidecarBlobCryptoError.keychainStatus(errSecDuplicateItem)
            }
            cachedKey = raced
            logKeyReady(raced, source: "keychain-after-duplicate")
            return raced
        default:
            logFailure("add", status: status)
            throw SidecarBlobCryptoError.keychainStatus(status)
        }
    }

    // Says once per instance where the key came from. Comparing the fingerprint
    // across two devices' logs shows whether they hold the same key; if they
    // don't, neither can decrypt the other's photos. Four bytes of a hash of a
    // random 256-bit key reveal nothing about the key.
    private func logKeyReady(_ key: SymmetricKey, source: String) {
        let digest = SHA256.hash(data: key.withUnsafeBytes { Data($0) })
        let fingerprint = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        Self.log.notice("blob key ready", metadata: [
            "source": .string(source),
            "fingerprint": .string(fingerprint),
        ])
    }

    // Names the failing call, which the thrown error can't: the same status
    // means different things on a read and on an add. Never logs key bytes.
    private func logFailure(_ operation: String, status: OSStatus) {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        Self.log.error("keychain call failed", metadata: [
            "op": .string(operation),
            "status": .stringConvertible(status),
            "message": .string(message),
        ])
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Match BOTH synchronizable and non-synchronizable items so a
            // lookup is unambiguous; we always WRITE synchronizable.
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
    }

    private func readKey() throws -> SymmetricKey? {
        var query = baseQuery()
        query[kSecReturnData as String] = kCFBooleanTrue as Any
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw SidecarBlobCryptoError.malformedKey
            }
            guard data.count == 32 else {
                throw SidecarBlobCryptoError.malformedKey
            }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            logFailure("read", status: status)
            throw SidecarBlobCryptoError.keychainStatus(status)
        }
    }

    private func addKey(_ keyData: Data) -> OSStatus {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: keyData,
            // Sync to the user's other devices: the synced `.dat` is useless
            // without the key on the receiving device.
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
            // A synchronizable item cannot be ThisDeviceOnly — use the
            // device-agnostic after-first-unlock accessibility class.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(attributes as CFDictionary, nil)
    }
}
#endif
