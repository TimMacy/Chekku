import Foundation
import Security

protocol CredentialStorage {
    func load() throws -> Credentials?
    func save(_ credentials: Credentials) throws
    func remove() throws
}

struct KeychainStorage: CredentialStorage {
    private let service = "com.chekku.app"
    private let account = "connection"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func load() throws -> Credentials? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else {
            throw WeTrakrError.message("The saved connection couldn't be read from Keychain.")
        }
        return try JSONDecoder().decode(Credentials.self, from: data)
    }

    func save(_ credentials: Credentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let changes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            try check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw WeTrakrError.message("Keychain couldn't save or read the connection (error \(status)).")
        }
    }
}

@MainActor
protocol QueueStorage {
    func load() throws -> QueueSnapshot?
    func save(_ snapshot: QueueSnapshot) throws
    func remove() throws
}

struct FileQueueStorage: QueueStorage {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.chekku.app", isDirectory: true)
            .appendingPathComponent("up-next.json")
    }

    func load() throws -> QueueSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(QueueSnapshot.self, from: Data(contentsOf: fileURL))
    }

    func save(_ snapshot: QueueSnapshot) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
    }

    func remove() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}
