import Foundation
import os

/// Manages API keys using secure Keychain storage.
final class APIKeyManager {
    static let shared = APIKeyManager()

    static let bundledKeychainIdentifier = "voiceInkAPIKeyBundleV1"

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "APIKeyManager")
    private let keychain = KeychainService.shared
    private let cachedKeys = OSAllocatedUnfairLock(initialState: [String: String]())
    private let hasLoadedBundle = OSAllocatedUnfairLock(initialState: false)
    private let bundleWriteLock = NSLock()
    private let bundleKeyIdentifier: String
    private let protectsUserCredentialsDuringTests: Bool

    /// Stable provider-to-Keychain identifiers retained for migration compatibility.
    private static let providerToKeychainKey: [String: String] = [
        "groq": "groqAPIKey",
        "deepgram": "deepgramAPIKey",
        "cerebras": "cerebrasAPIKey",
        "gemini": "geminiAPIKey",
        "mistral": "mistralAPIKey",
        "elevenlabs": "elevenLabsAPIKey",
        "soniox": "sonioxAPIKey",
        "speechmatics": "speechmaticsAPIKey",
        "assemblyai": "assemblyAIAPIKey",
        "xai": "xaiAPIKey",
        "cartesia": "cartesiaAPIKey",
        "doubao speech": "doubaoSpeechAPIKey",
        "alibaba cloud qwen": "aliyunQwenAPIKey",
        "openai": "openAIAPIKey",
        "anthropic": "anthropicAPIKey",
        "openrouter": "openRouterAPIKey",
    ]

    init(
        bundleKeyIdentifier: String = APIKeyManager.bundledKeychainIdentifier,
        protectsUserCredentialsDuringTests: Bool = true
    ) {
        self.bundleKeyIdentifier = bundleKeyIdentifier
        self.protectsUserCredentialsDuringTests = protectsUserCredentialsDuringTests
    }

    /// Loads the consolidated credential bundle with one Keychain request.
    /// Older per-provider items are migrated lazily the first time they are
    /// needed, then become part of this bundle for subsequent app updates.
    @discardableResult
    func preloadAllAPIKeys(allowAuthenticationUI: Bool = true) -> Bool {
        guard !shouldProtectUserCredentials else { return true }
        if hasLoadedBundle.withLock({ $0 }) {
            return true
        }

        let values: [String: String]
        switch keychain.readData(
            forKey: bundleKeyIdentifier,
            syncable: false,
            storagePolicy: .keychainOnly,
            allowAuthenticationUI: allowAuthenticationUI
        ) {
        case .value(let data):
            guard let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
                logger.error("The consolidated credential bundle could not be decoded")
                return false
            }
            values = decoded
        case .notFound:
            values = [:]
        case .unavailable(let status):
            logger.error(
                "The consolidated credential bundle is unavailable, status: \(status, privacy: .public)"
            )
            return false
        }

        cachedKeys.withLock { cache in
            cache.merge(values) { _, newValue in newValue }
        }
        hasLoadedBundle.withLock { $0 = true }
        logger.info("Preloaded \(values.count, privacy: .public) credentials from one Keychain bundle")
        return true
    }

    // MARK: - Standard Provider API Keys

    /// Saves an API key for a provider.
    @discardableResult
    func saveAPIKey(_ key: String, forProvider provider: String) -> Bool {
        guard prepareBundleForMutation() else { return false }
        let keyIdentifier = keychainIdentifier(forProvider: provider)
        let legacySuccess = keychain.save(
            key,
            forKey: keyIdentifier,
            syncable: false,
            storagePolicy: Self.storagePolicy(forProvider: provider)
        )
        cache(key, forIdentifier: keyIdentifier)
        let bundleSuccess = persistCachedKeys()
        if bundleSuccess {
            logger.info(
                "Saved API key for provider: \(provider, privacy: .public) with key: \(keyIdentifier, privacy: .public)"
            )
        }
        if !legacySuccess {
            logger.warning("Failed to update legacy per-provider Keychain item for: \(keyIdentifier, privacy: .public)")
        }
        return bundleSuccess
    }

    /// Retrieves an API key for a provider.
    func getAPIKey(forProvider provider: String, allowAuthenticationUI: Bool = true) -> String? {
        guard !shouldProtectUserCredentials else { return nil }
        let keyIdentifier = keychainIdentifier(forProvider: provider)
        return getCachedOrStoredKey(
            forIdentifier: keyIdentifier,
            storagePolicy: Self.storagePolicy(forProvider: provider),
            allowAuthenticationUI: allowAuthenticationUI
        )
    }

    /// Deletes an API key for a provider.
    @discardableResult
    func deleteAPIKey(forProvider provider: String) -> Bool {
        guard prepareBundleForMutation() else { return false }
        let keyIdentifier = keychainIdentifier(forProvider: provider)
        let legacySuccess = keychain.delete(
            forKey: keyIdentifier,
            syncable: false,
            storagePolicy: Self.storagePolicy(forProvider: provider)
        )
        removeCachedKey(forIdentifier: keyIdentifier)
        let bundleSuccess = persistCachedKeys()
        if bundleSuccess {
            logger.info("Deleted API key for provider: \(provider, privacy: .public)")
        }
        if !legacySuccess {
            logger.warning("Failed to delete legacy per-provider Keychain item for: \(keyIdentifier, privacy: .public)")
        }
        return bundleSuccess
    }

    /// Checks if an API key exists for a provider.
    func hasAPIKey(forProvider provider: String) -> Bool {
        guard !shouldProtectUserCredentials else { return false }
        let keyIdentifier = keychainIdentifier(forProvider: provider)
        if cachedKeys.withLock({ $0[keyIdentifier] != nil }) {
            return true
        }
        return keychain.exists(
            forKey: keyIdentifier,
            syncable: false,
            storagePolicy: Self.storagePolicy(forProvider: provider)
        )
    }

    // MARK: - Custom Model API Keys

    /// Saves an API key for a custom model.
    @discardableResult
    func saveCustomModelAPIKey(_ key: String, forModelId modelId: UUID) -> Bool {
        guard prepareBundleForMutation() else { return false }
        let keyIdentifier = customModelKeyIdentifier(for: modelId)
        let legacySuccess = keychain.save(key, forKey: keyIdentifier, syncable: false, storagePolicy: .keychainOnly)
        cache(key, forIdentifier: keyIdentifier)
        let bundleSuccess = persistCachedKeys()
        if bundleSuccess {
            logger.info("Saved API key for custom model: \(modelId.uuidString, privacy: .public)")
        }
        if !legacySuccess {
            logger.warning("Failed to update legacy custom-model Keychain item: \(keyIdentifier, privacy: .public)")
        }
        return bundleSuccess
    }

    /// Retrieves an API key for a custom model.
    func getCustomModelAPIKey(forModelId modelId: UUID, allowAuthenticationUI: Bool = true) -> String? {
        guard !shouldProtectUserCredentials else { return nil }
        let keyIdentifier = customModelKeyIdentifier(for: modelId)
        return getCachedOrStoredKey(
            forIdentifier: keyIdentifier,
            storagePolicy: .keychainOnly,
            allowAuthenticationUI: allowAuthenticationUI
        )
    }

    /// Deletes an API key for a custom model.
    @discardableResult
    func deleteCustomModelAPIKey(forModelId modelId: UUID) -> Bool {
        guard prepareBundleForMutation() else { return false }
        let keyIdentifier = customModelKeyIdentifier(for: modelId)
        let legacySuccess = keychain.delete(forKey: keyIdentifier, syncable: false, storagePolicy: .keychainOnly)
        removeCachedKey(forIdentifier: keyIdentifier)
        let bundleSuccess = persistCachedKeys()
        if bundleSuccess {
            logger.info("Deleted API key for custom model: \(modelId.uuidString, privacy: .public)")
        }
        if !legacySuccess {
            logger.warning("Failed to delete legacy custom-model Keychain item: \(keyIdentifier, privacy: .public)")
        }
        return bundleSuccess
    }

    // MARK: - Custom AI Provider API Keys

    @discardableResult
    func saveCustomAIProviderAPIKey(_ key: String, forProviderId providerId: UUID) -> Bool {
        guard prepareBundleForMutation() else { return false }
        let keyIdentifier = customAIProviderKeyIdentifier(for: providerId)
        let legacySuccess = keychain.save(key, forKey: keyIdentifier, syncable: false, storagePolicy: .keychainOnly)
        cache(key, forIdentifier: keyIdentifier)
        let bundleSuccess = persistCachedKeys()
        if bundleSuccess {
            logger.info("Saved API key for custom AI provider: \(providerId.uuidString, privacy: .public)")
        }
        if !legacySuccess {
            logger.warning("Failed to update legacy custom-provider Keychain item: \(keyIdentifier, privacy: .public)")
        }
        return bundleSuccess
    }

    func getCustomAIProviderAPIKey(
        forProviderId providerId: UUID,
        allowAuthenticationUI: Bool = true
    ) -> String? {
        guard !shouldProtectUserCredentials else { return nil }
        let keyIdentifier = customAIProviderKeyIdentifier(for: providerId)
        return getCachedOrStoredKey(
            forIdentifier: keyIdentifier,
            storagePolicy: .keychainOnly,
            allowAuthenticationUI: allowAuthenticationUI
        )
    }

    @discardableResult
    func deleteCustomAIProviderAPIKey(forProviderId providerId: UUID) -> Bool {
        guard prepareBundleForMutation() else { return false }
        let keyIdentifier = customAIProviderKeyIdentifier(for: providerId)
        let legacySuccess = keychain.delete(forKey: keyIdentifier, syncable: false, storagePolicy: .keychainOnly)
        removeCachedKey(forIdentifier: keyIdentifier)
        let bundleSuccess = persistCachedKeys()
        if bundleSuccess {
            logger.info("Deleted API key for custom AI provider: \(providerId.uuidString, privacy: .public)")
        }
        if !legacySuccess {
            logger.warning("Failed to delete legacy custom-provider Keychain item: \(keyIdentifier, privacy: .public)")
        }
        return bundleSuccess
    }

    // MARK: - Key Identifier Helpers

    /// Returns Keychain identifier for a provider (case-insensitive).
    private func keychainIdentifier(forProvider provider: String) -> String {
        let lowercased = provider.lowercased()
        if let mapped = Self.providerToKeychainKey[lowercased] {
            return mapped
        }
        return "\(lowercased)APIKey"
    }

    static func storagePolicy(forProvider provider: String) -> KeychainStoragePolicy {
        .keychainOnly
    }

    /// Generates Keychain identifier for custom model API key.
    private func customModelKeyIdentifier(for modelId: UUID) -> String {
        "customModel_\(modelId.uuidString)_APIKey"
    }

    private func customAIProviderKeyIdentifier(for providerId: UUID) -> String {
        "customAIProvider_\(providerId.uuidString)_APIKey"
    }

    private func getCachedOrStoredKey(
        forIdentifier identifier: String,
        storagePolicy: KeychainStoragePolicy,
        allowAuthenticationUI: Bool
    ) -> String? {
        if let cached = cachedKeys.withLock({ $0[identifier] }) {
            return cached
        }

        guard
            let stored = keychain.getString(
                forKey: identifier,
                syncable: false,
                storagePolicy: storagePolicy,
                allowAuthenticationUI: allowAuthenticationUI
            )
        else {
            return nil
        }

        cache(stored, forIdentifier: identifier)
        if !persistCachedKeys() {
            logger.warning("Failed to migrate legacy Keychain item into the consolidated credential bundle")
        }
        return stored
    }

    private func cache(_ key: String, forIdentifier identifier: String) {
        cachedKeys.withLock { cache in
            cache[identifier] = key
        }
    }

    private func removeCachedKey(forIdentifier identifier: String) {
        cachedKeys.withLock { cache in
            _ = cache.removeValue(forKey: identifier)
        }
    }

    private func persistCachedKeys() -> Bool {
        guard hasLoadedBundle.withLock({ $0 }) else { return false }

        bundleWriteLock.lock()
        defer { bundleWriteLock.unlock() }

        let values = cachedKeys.withLock { $0 }
        guard let data = try? JSONEncoder().encode(values) else {
            logger.error("Failed to encode the consolidated credential bundle")
            return false
        }

        return keychain.save(
            data: data,
            forKey: bundleKeyIdentifier,
            syncable: false,
            storagePolicy: .keychainOnly
        )
    }

    private func prepareBundleForMutation() -> Bool {
        guard !shouldProtectUserCredentials else { return false }
        return hasLoadedBundle.withLock { $0 } || preloadAllAPIKeys()
    }

    /// Unit tests launch the complete application as an unsigned host. Keep
    /// that host away from the user's real credentials; dedicated Keychain
    /// tests call `KeychainService` directly with isolated temporary keys.
    private var shouldProtectUserCredentials: Bool {
        protectsUserCredentialsDuringTests
            && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
