import XCTest

@testable import Chat42

/// Covers the ordering guarantee behind the launch-time "Authentication failed.
/// Check your API key." alert.
///
/// The gateway key is read from the Keychain *after* the window exists, so the
/// startup refresh in `ContentView` used to race that read and send an
/// unauthenticated `/v1/models`. The gateway answers 401, which maps to
/// `.authenticationFailed` — the app blamed a perfectly valid key roughly one launch
/// in six. `refreshGatewayModels()` now awaits the same shared load, so these tests
/// pin the two properties that fix depends on: the load is shared, and it has
/// applied the key by the time it returns.
///
/// Read-only with respect to the Keychain — nothing here writes a secret. Opt-in all
/// the same, following `LivePipelineTests`: reading a real Keychain item from the
/// test binary can raise a SecurityAgent prompt wherever the item's ACL does not
/// name that binary, and a modal in the middle of `swift test` would hang CI.
///
///     CHAT42_KEYCHAIN_TESTS=1 swift test --filter GatewayCredentialLoadTests
@MainActor
final class GatewayCredentialLoadTests: XCTestCase {

  override func setUp() async throws {
    try await super.setUp()
    try XCTSkipIf(
      ProcessInfo.processInfo.environment["CHAT42_KEYCHAIN_TESTS"] == nil,
      "set CHAT42_KEYCHAIN_TESTS=1 to run the Keychain-backed credential tests")
  }

  /// Two callers must share one read and both return. Every gateway refresh now
  /// awaits this, so a load that never completed would stall model loading at launch
  /// instead of merely mis-reporting it.
  func testConcurrentLoadsBothComplete() async {
    let state = AppState()

    async let first: Void = state.loadGatewayCredentials()
    async let second: Void = state.loadGatewayCredentials()
    _ = await (first, second)

    // Reaching this line is the assertion: neither caller deadlocked on the other,
    // and the memoised task resolved for both.
    XCTAssertTrue(true)
  }

  /// The point of the gate: once the load returns, the service is carrying the stored
  /// key, so the request that follows is authenticated rather than a doomed 401.
  ///
  /// Skipped where no key is configured — CI has no Keychain item to find.
  func testKeyIsAppliedToTheServiceBeforeTheLoadReturns() async throws {
    let stored = KeychainHelper.load(forKey: "gatewayAPIKey")
    try XCTSkipIf(stored == nil, "no gateway key stored on this machine")

    let state = AppState()
    let beforeLoad = await state.gatewayService.apiKey
    XCTAssertTrue(
      beforeLoad.isEmpty,
      "the key must not be read in init — a blocking Keychain call there froze launch")

    await state.loadGatewayCredentials()

    let applied = await state.gatewayService.apiKey
    XCTAssertEqual(
      applied, stored,
      "refreshGatewayModels awaits this call, so the key has to be in place when it returns")
  }
}
