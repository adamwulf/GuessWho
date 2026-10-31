import Foundation
import CryptoKit
import Logging

#if canImport(Security)
import Security
#endif

// Reads `.blob` `.dat` payloads that older builds encrypted.
//
// New `.dat` files are not encrypted (see `FileSystemSidecarStore.writeBlob`), so
// writing or reading one never runs this. Files from older builds are AES-GCM
// sealed under a 256-bit key in the iCloud-synchronizable keychain, and this
// decrypts them where that key can be reached. Replacing an older photo reads it
// first to snapshot it, so a save can log a failure here, which is harmless. Mac
// Catalyst can't reach the key: the app claims `<TeamID>.` App Groups its
// provisioning profile doesn't authorize, so the keychain ignores its
// entitlements and answers -34018.
//
// The protocol is injectable so unit tests pass a deterministic in-memory key
// (`InMemoryBlobCrypto`) and never touch the real keychain; production uses the
// keychain-backed `KeychainBlobCrypto`.
@_spi(ConflictReconcile)
public protocol SidecarBlobCrypto: AnyObject {
    // Decrypt a `combined` AES-GCM sealed box (nonce || ciphertext || tag).
    func decrypt(_ ciphertext: Data) throws -> Data
}

@_spi(ConflictReconcile)
public enum SidecarBlobCryptoError: LocalizedError, Equatable {
    // The keychain returned an unexpected OSStatus, or holds no key.
    case keychainStatus(Int32)
    // The keychain held an item but its bytes weren't a valid 256-bit key.
    case malformedKey
    // No keychain is available on this platform (non-Apple SwiftPM CI).
    case keychainUnavailable
    // An older encrypted `.dat` can't be opened on this device, because the key
    // is out of reach or isn't the one that sealed it. The store reports every
    // decryption failure this way, and logs the cause.
    case cannotDecrypt

    // Written to the logs, and shown if one of these reaches an alert, so this
    // speaks about photos and keeps the OSStatus visible.
    public var errorDescription: String? {
        switch self {
        case .keychainStatus(let status):
            return "The keychain wouldn’t provide the key that protects your photos (error \(status))."
        case .malformedKey:
            return "The key that protects your photos isn’t usable."
        case .keychainUnavailable:
            return "This device has no keychain to protect your photos."
        case .cannotDecrypt:
            return "This photo was protected on another device and can’t be read here."
        }
    }
}

#if !canImport(Security)
// Fallback used only where Security (and thus the keychain) is unavailable —
// e.g. linux SwiftPM CI.
final class UnavailableBlobCrypto: SidecarBlobCrypto {
    func decrypt(_ ciphertext: Data) throws -> Data {
        throw SidecarBlobCryptoError.keychainUnavailable
    }
}
#endif

// MARK: - In-memory (tests)

/// A crypto seam backed by a caller-supplied symmetric key held only in memory,
/// so tests exercise decryption WITHOUT reading the real (synchronizable)
/// keychain. Default init mints a random key per instance; pass `key:` for
/// determinism. `encrypt` exists only so tests can build a file the way older
/// builds did.
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
/// Production crypto seam. Loads the 256-bit key from the iCloud-synchronizable
/// keychain and decrypts with AES-GCM. It never creates a key: a new key couldn't
/// open a file sealed under the old one.
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

    public func decrypt(_ ciphertext: Data) throws -> Data {
        let key = try loadKey()
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: key)
    }

    private func loadKey() throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let cachedKey { return cachedKey }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Match BOTH synchronizable and non-synchronizable items.
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        query[kSecReturnData as String] = kCFBooleanTrue as Any
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            logFailure("read", status: status)
            throw SidecarBlobCryptoError.keychainStatus(status)
        }
        guard let data = item as? Data, data.count == 32 else {
            throw SidecarBlobCryptoError.malformedKey
        }
        let key = SymmetricKey(data: data)
        cachedKey = key
        logKeyLoaded(key)
        return key
    }

    // Comparing the fingerprint across two devices' logs shows whether they hold
    // the same key; if they don't, neither can decrypt the other's older photos.
    // Four bytes of a hash of a random 256-bit key reveal nothing about the key.
    private func logKeyLoaded(_ key: SymmetricKey) {
        let digest = SHA256.hash(data: key.withUnsafeBytes { Data($0) })
        let fingerprint = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        Self.log.notice("blob key loaded", metadata: ["fingerprint": .string(fingerprint)])
    }

    // Never logs key bytes.
    private func logFailure(_ operation: String, status: OSStatus) {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        Self.log.error("keychain call failed", metadata: [
            "op": .string(operation),
            "status": .stringConvertible(status),
            "message": .string(message),
        ])
    }
}
#endif
