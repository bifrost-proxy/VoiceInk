import Foundation
import LocalAuthentication
import Security
import os

enum KeychainStoragePolicy: Equatable {
    /// Preserve the existing local-build compatibility behavior.
    case standard
    /// Never fall back to UserDefaults, even for locally signed builds.
    case keychainOnly
}

/// Securely stores and retrieves secrets using Keychain. Synchronization is
/// controlled independently with `syncable`; API key callers disable it.
/// Standard credentials use UserDefaults in local builds for compatibility,
/// while `.keychainOnly` never permits that fallback.
final class KeychainService {
    static let shared = KeychainService()

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "KeychainService")
    private let service = "com.prakashjoshipax.VoiceInk"

    #if LOCAL_BUILD
        private let defaults = UserDefaults.standard
        private let localPrefix = "LocalKeychain_"
    #endif

    private init() {}

    // MARK: - Public API

    /// Saves a string value to Keychain.
    @discardableResult
    func save(
        _ value: String,
        forKey key: String,
        syncable: Bool = true,
        storagePolicy: KeychainStoragePolicy = .standard
    ) -> Bool {
        guard let data = value.data(using: .utf8) else {
            logger.error("Failed to convert value to data for key: \(key, privacy: .public)")
            return false
        }
        return save(data: data, forKey: key, syncable: syncable, storagePolicy: storagePolicy)
    }

    /// Saves data to Keychain.
    @discardableResult
    func save(
        data: Data,
        forKey key: String,
        syncable: Bool = true,
        storagePolicy: KeychainStoragePolicy = .standard
    ) -> Bool {
        #if LOCAL_BUILD
            if storagePolicy == .standard {
                defaults.set(data, forKey: localPrefix + key)
                return true
            }
        #endif

        let query = baseQuery(forKey: key, syncable: syncable, storagePolicy: storagePolicy)
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecSuccess {
            removeLegacyLocalFallback(forKey: key, storagePolicy: storagePolicy)
            logger.info("Successfully updated keychain item for key: \(key, privacy: .public)")
            return true
        }

        guard updateStatus == errSecItemNotFound else {
            logger.error(
                "Failed to update keychain item for key: \(key, privacy: .public), status: \(updateStatus, privacy: .public)"
            )
            return false
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)

        if addStatus == errSecSuccess {
            removeLegacyLocalFallback(forKey: key, storagePolicy: storagePolicy)
            logger.info("Successfully saved keychain item for key: \(key, privacy: .public)")
            return true
        }

        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if retryStatus == errSecSuccess {
                removeLegacyLocalFallback(forKey: key, storagePolicy: storagePolicy)
                logger.info("Successfully updated concurrently created keychain item for key: \(key, privacy: .public)")
                return true
            }

            logger.error(
                "Failed to update concurrently created keychain item for key: \(key, privacy: .public), status: \(retryStatus, privacy: .public)"
            )
            return false
        }

        logger.error(
            "Failed to save keychain item for key: \(key, privacy: .public), status: \(addStatus, privacy: .public)"
        )
        return false
    }

    /// Retrieves a string value from Keychain.
    func getString(
        forKey key: String,
        syncable: Bool = true,
        storagePolicy: KeychainStoragePolicy = .standard,
        allowAuthenticationUI: Bool = true
    ) -> String? {
        guard
            let data = getData(
                forKey: key,
                syncable: syncable,
                storagePolicy: storagePolicy,
                allowAuthenticationUI: allowAuthenticationUI
            )
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Retrieves data from Keychain.
    func getData(
        forKey key: String,
        syncable: Bool = true,
        storagePolicy: KeychainStoragePolicy = .standard,
        allowAuthenticationUI: Bool = true
    ) -> Data? {
        #if LOCAL_BUILD
            if storagePolicy == .standard {
                return defaults.data(forKey: localPrefix + key)
            }
        #endif

        var query = baseQuery(forKey: key, syncable: syncable, storagePolicy: storagePolicy)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowAuthenticationUI {
            preventAuthenticationUI(in: &query)
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess {
            return result as? Data
        } else if status != errSecItemNotFound {
            logger.error(
                "Failed to retrieve keychain item for key: \(key, privacy: .public), status: \(status, privacy: .public)"
            )
        }

        #if LOCAL_BUILD
            if storagePolicy == .keychainOnly,
                let legacyData = defaults.data(forKey: localPrefix + key),
                save(data: legacyData, forKey: key, syncable: syncable, storagePolicy: .keychainOnly)
            {
                logger.info("Migrated legacy local credential into Keychain for key: \(key, privacy: .public)")
                return legacyData
            }
        #endif

        return nil
    }

    /// Deletes an item from Keychain.
    @discardableResult
    func delete(
        forKey key: String,
        syncable: Bool = true,
        storagePolicy: KeychainStoragePolicy = .standard
    ) -> Bool {
        #if LOCAL_BUILD
            if storagePolicy == .standard {
                defaults.removeObject(forKey: localPrefix + key)
                return true
            }
        #endif

        let query = baseQuery(forKey: key, syncable: syncable, storagePolicy: storagePolicy)
        let status = SecItemDelete(query as CFDictionary)

        if status == errSecSuccess || status == errSecItemNotFound {
            removeLegacyLocalFallback(forKey: key, storagePolicy: storagePolicy)
            if status == errSecSuccess {
                logger.info("Successfully deleted keychain item for key: \(key, privacy: .public)")
            }
            return true
        } else {
            logger.error(
                "Failed to delete keychain item for key: \(key, privacy: .public), status: \(status, privacy: .public)"
            )
            return false
        }
    }

    /// Checks if a key exists in Keychain.
    func exists(
        forKey key: String,
        syncable: Bool = true,
        storagePolicy: KeychainStoragePolicy = .standard
    ) -> Bool {
        #if LOCAL_BUILD
            if storagePolicy == .standard {
                return defaults.data(forKey: localPrefix + key) != nil
            }
            if storagePolicy == .keychainOnly {
                return getData(
                    forKey: key,
                    syncable: syncable,
                    storagePolicy: storagePolicy,
                    allowAuthenticationUI: false
                ) != nil
            }
        #endif

        var query = baseQuery(forKey: key, syncable: syncable, storagePolicy: storagePolicy)
        // A metadata-only query can report an item that this unsigned build
        // cannot decrypt without showing a Keychain authorization dialog.
        // Verify readable data without UI so background status checks never
        // block app startup or recording preflight.
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        preventAuthenticationUI(in: &query)

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return status == errSecSuccess
    }

    // MARK: - Private Helpers

    private func removeLegacyLocalFallback(forKey key: String, storagePolicy: KeychainStoragePolicy) {
        #if LOCAL_BUILD
            if storagePolicy == .keychainOnly {
                defaults.removeObject(forKey: localPrefix + key)
            }
        #endif
    }

    private func preventAuthenticationUI(in query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context

        // The login Keychain used by ad-hoc builds still relies on its legacy
        // ACL path and does not consistently honor LAContext alone. Supplying
        // both options prevents an unsigned background status check from
        // waiting indefinitely for a system authorization dialog.
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
    }

    /// Creates base Keychain query dictionary.
    private func baseQuery(
        forKey key: String,
        syncable: Bool,
        storagePolicy: KeychainStoragePolicy
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        #if LOCAL_BUILD
            // Ad-hoc builds do not have the application-identifier entitlement
            // required by the data-protection Keychain. Keychain-only secrets
            // stay encrypted in the user's login Keychain without iCloud sync.
            if storagePolicy == .keychainOnly {
                return query
            }
        #endif

        query[kSecUseDataProtectionKeychain as String] = true
        if syncable {
            query[kSecAttrSynchronizable as String] = kCFBooleanTrue
        }

        return query
    }
}
