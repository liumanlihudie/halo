import Flutter
import Foundation
import Security

struct KeychainCredentialMetadata {
  let service: String
  let account: String
  let createdAt: Date
  let updatedAt: Date
}

struct KeychainStoreFailure: Error, CustomStringConvertible {
  let channelCode: String

  init(status: OSStatus) {
    channelCode = switch status {
    case errSecInteractionNotAllowed, errSecAuthFailed:
      "locked"
    case errSecUserCanceled:
      "cancelled"
    case errSecItemNotFound:
      "not_found"
    case errSecParam:
      "invalid_arguments"
    case errSecNotAvailable:
      "unavailable"
    default:
      "unexpected"
    }
  }

  init(channelCode: String) {
    self.channelCode = channelCode
  }

  var description: String {
    "KeychainStoreFailure(\(channelCode))"
  }
}

final class IOSSecureCredentialStore {
  static let ownershipMarker = Data("com.halo.secure-credential.v1".utf8)

  func set(service: String, account: String, value: Data) throws {
    try validateLocation(service: service, account: account)
    let query = baseQuery(service: service, account: account)
    var addQuery = query
    addQuery[kSecValueData] = value
    addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    if addStatus == errSecSuccess {
      return
    }
    if addStatus != errSecDuplicateItem {
      throw KeychainStoreFailure(status: addStatus)
    }

    let update: [CFString: Any] = [
      kSecValueData: value,
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
    guard updateStatus == errSecSuccess else {
      throw KeychainStoreFailure(status: updateStatus)
    }
  }

  func get(service: String, account: String) throws -> Data? {
    try validateLocation(service: service, account: account)
    var query = baseQuery(service: service, account: account)
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess, let data = item as? Data else {
      throw KeychainStoreFailure(
        status: status == errSecSuccess ? errSecDecode : status
      )
    }
    return data
  }

  func delete(service: String, account: String) throws -> Bool {
    try validateLocation(service: service, account: account)
    let status = SecItemDelete(
      baseQuery(service: service, account: account) as CFDictionary
    )
    if status == errSecItemNotFound {
      return false
    }
    guard status == errSecSuccess else {
      throw KeychainStoreFailure(status: status)
    }
    return true
  }

  func listMetadata(service: String?) throws -> [KeychainCredentialMetadata] {
    if let service, !SecureCredentialIdentifier.isSafe(service, limit: 128) {
      throw KeychainStoreFailure(channelCode: "invalid_arguments")
    }
    var query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrGeneric: Self.ownershipMarker,
      kSecReturnAttributes: true,
      kSecMatchLimit: kSecMatchLimitAll,
    ]
    if let service {
      query[kSecAttrService] = service
    }
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound {
      return []
    }
    guard status == errSecSuccess, let rows = item as? [[CFString: Any]] else {
      throw KeychainStoreFailure(
        status: status == errSecSuccess ? errSecDecode : status
      )
    }
    return try rows.map { row in
      guard
        let service = row[kSecAttrService] as? String,
        let account = row[kSecAttrAccount] as? String,
        let createdAt = row[kSecAttrCreationDate] as? Date,
        let updatedAt = row[kSecAttrModificationDate] as? Date,
        SecureCredentialIdentifier.isSafe(service, limit: 128),
        SecureCredentialIdentifier.isSafe(account, limit: 256)
      else {
        throw KeychainStoreFailure(channelCode: "unexpected")
      }
      return KeychainCredentialMetadata(
        service: service,
        account: account,
        createdAt: createdAt,
        updatedAt: updatedAt
      )
    }
  }

  private func baseQuery(service: String, account: String) -> [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrGeneric: Self.ownershipMarker,
      kSecAttrService: service,
      kSecAttrAccount: account,
    ]
  }

  private func validateLocation(service: String, account: String) throws {
    guard
      SecureCredentialIdentifier.isSafe(service, limit: 128),
      SecureCredentialIdentifier.isSafe(account, limit: 256)
    else {
      throw KeychainStoreFailure(channelCode: "invalid_arguments")
    }
  }
}

enum SecureCredentialIdentifier {
  static func isSafe(_ value: String, limit: Int) -> Bool {
    guard !value.isEmpty, value.utf8.count <= limit else {
      return false
    }
    let hasUnsafeScalar = value.unicodeScalars.contains { scalar in
      let code = scalar.value
      return code <= 0x20
        || (0x7F...0x9F).contains(code)
        || code == 0x00AD
        || code == 0x061C
        || code == 0x180E
        || (0x200B...0x200F).contains(code)
        || (0x2028...0x202E).contains(code)
        || (0x2060...0x206F).contains(code)
        || code == 0xFEFF
        || (0xFFF9...0xFFFB).contains(code)
    }
    if hasUnsafeScalar {
      return false
    }

    let lower = value.lowercased()
    let allowedTokenScalars = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
    )
    let isCompleteOpenAIStyleToken = lower.hasPrefix("sk-")
      && value.utf8.count >= 23
      && value.unicodeScalars.allSatisfy(allowedTokenScalars.contains)
    return !isCompleteOpenAIStyleToken
  }
}

enum SecureCredentialStoreBridge {
  static let channelName = "halo/secure_credential_store"
  private static let maximumSecretBytes = 64 * 1024
  private static let maximumMetadataCount = 1024

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    let store = IOSSecureCredentialStore()
    channel.setMethodCallHandler { call, result in
      handle(call: call, store: store, result: result)
    }
  }

  private static func handle(
    call: FlutterMethodCall,
    store: IOSSecureCredentialStore,
    result: @escaping FlutterResult
  ) {
    guard let arguments = call.arguments as? [String: Any] else {
      result(fixedError(code: "invalid_arguments"))
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let response = try execute(
          method: call.method,
          arguments: arguments,
          store: store
        )
        DispatchQueue.main.async {
          result(response)
        }
      } catch let failure as KeychainStoreFailure {
        DispatchQueue.main.async {
          result(fixedError(code: failure.channelCode))
        }
      } catch {
        DispatchQueue.main.async {
          result(fixedError(code: "unexpected"))
        }
      }
    }
  }

  private static func execute(
    method: String,
    arguments: [String: Any],
    store: IOSSecureCredentialStore
  ) throws -> Any? {
    switch method {
    case "set":
      let (service, account) = try location(arguments)
      guard
        let typedData = arguments["value"] as? FlutterStandardTypedData,
        !typedData.data.isEmpty,
        typedData.data.count <= maximumSecretBytes
      else {
        throw KeychainStoreFailure(channelCode: "invalid_arguments")
      }
      var secret = mutableCopy(of: typedData.data)
      defer {
        wipe(&secret)
      }
      try store.set(service: service, account: account, value: secret)
      return nil
    case "get":
      let (service, account) = try location(arguments)
      guard var secret = try store.get(service: service, account: account) else {
        return nil
      }
      defer {
        wipe(&secret)
      }
      let transferCopy = mutableCopy(of: secret)
      return FlutterStandardTypedData(bytes: transferCopy)
    case "delete":
      let (service, account) = try location(arguments)
      return try store.delete(service: service, account: account)
    case "listMetadata":
      let service: String?
      if let rawService = arguments["service"] {
        guard
          let parsed = rawService as? String,
          SecureCredentialIdentifier.isSafe(parsed, limit: 128)
        else {
          throw KeychainStoreFailure(channelCode: "invalid_arguments")
        }
        service = parsed
      } else {
        service = nil
      }
      let metadata = try store.listMetadata(service: service)
      guard metadata.count <= maximumMetadataCount else {
        throw KeychainStoreFailure(channelCode: "unexpected")
      }
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      return metadata.map { item in
        [
          "service": item.service,
          "account": item.account,
          "createdAt": formatter.string(from: item.createdAt),
          "updatedAt": formatter.string(from: item.updatedAt),
        ]
      }
    default:
      throw KeychainStoreFailure(channelCode: "unavailable")
    }
  }

  private static func location(_ arguments: [String: Any]) throws -> (String, String) {
    guard
      let service = arguments["service"] as? String,
      let account = arguments["account"] as? String,
      SecureCredentialIdentifier.isSafe(service, limit: 128),
      SecureCredentialIdentifier.isSafe(account, limit: 256)
    else {
      throw KeychainStoreFailure(channelCode: "invalid_arguments")
    }
    return (service, account)
  }

  private static func mutableCopy(of source: Data) -> Data {
    var copy = Data(count: source.count)
    copy.withUnsafeMutableBytes { destination in
      source.withUnsafeBytes { sourceBytes in
        destination.copyMemory(from: sourceBytes)
      }
    }
    return copy
  }

  private static func wipe(_ data: inout Data) {
    _ = data.withUnsafeMutableBytes { bytes in
      bytes.initializeMemory(as: UInt8.self, repeating: 0)
    }
    data.removeAll(keepingCapacity: false)
  }

  private static func fixedError(code: String) -> FlutterError {
    FlutterError(code: code, message: "Secure credential operation failed", details: nil)
  }
}
