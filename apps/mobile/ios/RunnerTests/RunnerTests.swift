import Flutter
import Security
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {
  private var service: String!
  private let store = IOSSecureCredentialStore()

  override func setUp() {
    super.setUp()
    service = "com.halo.tests.\(UUID().uuidString)"
  }

  override func tearDown() {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service as CFString,
    ]
    _ = SecItemDelete(query as CFDictionary)
    service = nil
    super.tearDown()
  }

  func testKeychainCreateReadUpdateListAndDelete() throws {
    let account = "primary"
    try store.set(service: service, account: account, value: Data("first".utf8))
    XCTAssertEqual(try store.get(service: service, account: account), Data("first".utf8))

    try store.set(service: service, account: account, value: Data("updated".utf8))
    XCTAssertEqual(try store.get(service: service, account: account), Data("updated".utf8))

    let metadata = try store.listMetadata(service: service)
    XCTAssertEqual(metadata.count, 1)
    XCTAssertEqual(metadata.first?.service, service)
    XCTAssertEqual(metadata.first?.account, account)
    XCTAssertNotNil(metadata.first?.createdAt)
    XCTAssertNotNil(metadata.first?.updatedAt)

    XCTAssertTrue(try store.delete(service: service, account: account))
    XCTAssertNil(try store.get(service: service, account: account))
    XCTAssertFalse(try store.delete(service: service, account: account))
  }

  func testKeychainItemUsesDeviceOnlyAfterFirstUnlockAccessibility() throws {
    try store.set(service: service, account: "accessibility", value: Data("secret".utf8))
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrGeneric: IOSSecureCredentialStore.ownershipMarker,
      kSecAttrService: service as CFString,
      kSecAttrAccount: "accessibility" as CFString,
      kSecReturnAttributes: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?

    XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &item), errSecSuccess)
    let attributes = try XCTUnwrap(item as? [CFString: Any])
    XCTAssertEqual(
      attributes[kSecAttrAccessible] as? String,
      kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
    )
  }

  func testConcurrentKeychainWritesRemainIndependent() throws {
    let queue = DispatchQueue(label: "com.halo.tests.keychain", attributes: .concurrent)
    let group = DispatchGroup()
    let lock = NSLock()
    var failures: [Error] = []

    for index in 0..<12 {
      group.enter()
      queue.async {
        defer { group.leave() }
        do {
          try self.store.set(
            service: self.service,
            account: "account-\(index)",
            value: Data("value-\(index)".utf8)
          )
        } catch {
          lock.lock()
          failures.append(error)
          lock.unlock()
        }
      }
    }

    XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
    XCTAssertTrue(failures.isEmpty)
    XCTAssertEqual(try store.listMetadata(service: service).count, 12)
  }

  func testOSStatusMappingIsFixedAndSafe() {
    XCTAssertEqual(KeychainStoreFailure(status: errSecInteractionNotAllowed).channelCode, "locked")
    XCTAssertEqual(KeychainStoreFailure(status: errSecAuthFailed).channelCode, "locked")
    XCTAssertEqual(KeychainStoreFailure(status: errSecUserCanceled).channelCode, "cancelled")
    XCTAssertEqual(KeychainStoreFailure(status: errSecItemNotFound).channelCode, "not_found")
    XCTAssertEqual(KeychainStoreFailure(status: errSecParam).channelCode, "invalid_arguments")
    XCTAssertEqual(KeychainStoreFailure(status: errSecNotAvailable).channelCode, "unavailable")
    XCTAssertEqual(KeychainStoreFailure(status: -999_999).channelCode, "unexpected")
    XCTAssertFalse(KeychainStoreFailure(status: -999_999).description.contains("-999999"))
  }

  func testHaloOwnershipDoesNotExposeOrMutateUnrelatedGenericPasswords() throws {
    let unrelatedAccount = "collision"
    let unrelatedValue = Data("unrelated-secret".utf8)
    let unrelatedQuery: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service as CFString,
      kSecAttrAccount: unrelatedAccount as CFString,
    ]
    var addQuery = unrelatedQuery
    addQuery[kSecValueData] = unrelatedValue
    addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    XCTAssertEqual(SecItemAdd(addQuery as CFDictionary, nil), errSecSuccess)

    XCTAssertNil(try store.get(service: service, account: unrelatedAccount))
    XCTAssertFalse(try store.delete(service: service, account: unrelatedAccount))
    XCTAssertThrowsError(
      try store.set(
        service: service,
        account: unrelatedAccount,
        value: Data("must-not-overwrite".utf8)
      )
    )

    try store.set(service: service, account: "owned", value: Data("owned-first".utf8))
    XCTAssertEqual(try store.listMetadata(service: nil).filter {
      $0.service == self.service
    }.map(\.account), ["owned"])
    try store.set(service: service, account: "owned", value: Data("owned-updated".utf8))
    XCTAssertTrue(try store.delete(service: service, account: "owned"))

    var unrelatedItem: CFTypeRef?
    var readQuery = unrelatedQuery
    readQuery[kSecReturnData] = true
    readQuery[kSecMatchLimit] = kSecMatchLimitOne
    XCTAssertEqual(SecItemCopyMatching(readQuery as CFDictionary, &unrelatedItem), errSecSuccess)
    XCTAssertEqual(unrelatedItem as? Data, unrelatedValue)
  }

  func testIdentifierCredentialFixtureMatchesDartBoundary() {
    let completeToken = "sk-live-abcdefghijklmnopqrstuvwxyz012345"
    XCTAssertFalse(SecureCredentialIdentifier.isSafe(completeToken, limit: 256))
    XCTAssertThrowsError(
      try store.set(service: service, account: completeToken, value: Data("value".utf8))
    )

    let locatorIdentifiers = [
      "BearerTeamAccount",
      "asia-production",
      "aiza-production",
      "apikey-team",
      "OpenRouterProductionAccount2026",
    ]
    for value in locatorIdentifiers {
      XCTAssertTrue(SecureCredentialIdentifier.isSafe(value, limit: 256))
    }
    XCTAssertTrue(SecureCredentialIdentifier.isSafe("com.halo.provider", limit: 128))
    XCTAssertTrue(SecureCredentialIdentifier.isSafe("user@example.com", limit: 256))
  }

  func testIdentifierUTF8ByteLimitsMatchDartBoundary() {
    let acceptedService = String(repeating: "a", count: 124) + "😀"
    let rejectedService = String(repeating: "a", count: 125) + "😀"
    let acceptedAccount = String(repeating: "a", count: 253) + "e\u{0301}"
    let rejectedAccount = String(repeating: "a", count: 254) + "e\u{0301}"

    XCTAssertEqual(acceptedService.utf8.count, 128)
    XCTAssertEqual(rejectedService.utf8.count, 129)
    XCTAssertEqual(acceptedAccount.utf8.count, 256)
    XCTAssertEqual(rejectedAccount.utf8.count, 257)
    XCTAssertTrue(SecureCredentialIdentifier.isSafe(acceptedService, limit: 128))
    XCTAssertFalse(SecureCredentialIdentifier.isSafe(rejectedService, limit: 128))
    XCTAssertTrue(SecureCredentialIdentifier.isSafe(acceptedAccount, limit: 256))
    XCTAssertFalse(SecureCredentialIdentifier.isSafe(rejectedAccount, limit: 256))
  }
}
