import Dependencies
import DependenciesMacros
import Foundation
import Security

private let openAIKeychainService = "com.kitlangton.Hex.openai"
private let openAIKeychainAccount = "api-key"

@DependencyClient
struct OpenAIKeychainClient {
	var loadAPIKey: @Sendable () throws -> String?
	var saveAPIKey: @Sendable (String) throws -> Void
	var deleteAPIKey: @Sendable () throws -> Void
	var hasAPIKey: @Sendable () -> Bool = { false }
}

extension OpenAIKeychainClient: DependencyKey {
	static var liveValue: Self {
		Self(
			loadAPIKey: {
				try OpenAIKeychain.load()
			},
			saveAPIKey: { key in
				try OpenAIKeychain.save(key)
			},
			deleteAPIKey: {
				try OpenAIKeychain.delete()
			},
			hasAPIKey: {
				(try? OpenAIKeychain.load())?.isEmpty == false
			}
		)
	}
}

extension DependencyValues {
	var openAIKeychain: OpenAIKeychainClient {
		get { self[OpenAIKeychainClient.self] }
		set { self[OpenAIKeychainClient.self] = newValue }
	}
}

private enum OpenAIKeychain {
	static func load() throws -> String? {
		var query = baseQuery()
		query[kSecReturnData as String] = true
		query[kSecMatchLimit as String] = kSecMatchLimitOne

		var item: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &item)
		if status == errSecItemNotFound { return nil }
		guard status == errSecSuccess else { throw keychainError(status) }
		guard let data = item as? Data else { return nil }
		return String(data: data, encoding: .utf8)
	}

	static func save(_ key: String) throws {
		let data = Data(key.utf8)
		var query = baseQuery()
		query[kSecValueData as String] = data
		query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

		let status = SecItemAdd(query as CFDictionary, nil)
		if status == errSecDuplicateItem {
			let update = [kSecValueData as String: data]
			let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary)
			guard updateStatus == errSecSuccess else { throw keychainError(updateStatus) }
			return
		}
		guard status == errSecSuccess else { throw keychainError(status) }
	}

	static func delete() throws {
		let status = SecItemDelete(baseQuery() as CFDictionary)
		if status == errSecItemNotFound { return }
		guard status == errSecSuccess else { throw keychainError(status) }
	}

	private static func baseQuery() -> [String: Any] {
		[
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: openAIKeychainService,
			kSecAttrAccount as String: openAIKeychainAccount
		]
	}

	private static func keychainError(_ status: OSStatus) -> NSError {
		NSError(
			domain: "OpenAIKeychain",
			code: Int(status),
			userInfo: [NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"]
		)
	}
}
