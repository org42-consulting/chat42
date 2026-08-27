import XCTest

@testable import Chat42

final class GatewayFailureMapperTests: XCTestCase {

  private func body(_ json: String) -> Data { Data(json.utf8) }

  // MARK: - Auth

  func testUnauthorizedMapsToAuthFailure() {
    for status in [401, 403] {
      guard case .authenticationFailed = GatewayFailureMapper.error(status: status, body: Data())
      else {
        return XCTFail("HTTP \(status) should map to authenticationFailed")
      }
    }
  }

  // MARK: - Provider messages

  func testProviderMessageIsPreferredOverStatusCode() {
    let error = GatewayFailureMapper.error(
      status: 500,
      body: body(#"{"error":{"message":"upstream exploded","type":"server_error"}}"#))
    guard case .apiError(let message) = error else { return XCTFail("expected apiError") }
    XCTAssertEqual(message, "upstream exploded")
  }

  /// Some gateways send `code` as a number. A strict decode would throw away the
  /// message, which is the only part worth showing.
  func testNumericErrorCodeStillYieldsTheMessage() {
    let error = GatewayFailureMapper.error(
      status: 500,
      body: body(#"{"error":{"message":"rate limited","code":429}}"#))
    guard case .apiError(let message) = error else { return XCTFail("expected apiError") }
    XCTAssertEqual(message, "rate limited")
  }

  func testNonEnvelopeBodyIsShownRaw() {
    let error = GatewayFailureMapper.error(status: 502, body: body("Bad Gateway"))
    guard case .apiError(let message) = error else { return XCTFail("expected apiError") }
    XCTAssertEqual(message, "Bad Gateway")
  }

  /// A recognisable envelope with no message must not be dumped on the user as raw
  /// JSON.
  func testMessagelessEnvelopeFallsBackToStatus() {
    let error = GatewayFailureMapper.error(
      status: 500, body: body(#"{"error":{"message":"","type":"x"}}"#))
    guard case .invalidResponse(let status) = error else {
      return XCTFail("expected invalidResponse, got \(error)")
    }
    XCTAssertEqual(status, 500)
  }

  func testMessagelessNotFoundMapsToModelUnavailable() {
    let error = GatewayFailureMapper.error(status: 404, body: Data(), model: "imagen-3")
    guard case .modelNotAvailable(let model) = error else {
      return XCTFail("expected modelNotAvailable")
    }
    XCTAssertEqual(model, "imagen-3")
  }

  // MARK: - Temperature rejection
  //
  // Each of these is a phrasing a real provider has returned. Getting the
  // classification wrong means either a pointless retry or an error the user
  // cannot act on.

  func testTemperatureRejectionByParamField() {
    let error = GatewayFailureMapper.error(
      status: 400,
      body: body(#"{"error":{"message":"nope","param":"temperature"}}"#))
    guard case .unsupportedParameter(let name) = error else {
      return XCTFail("expected unsupportedParameter")
    }
    XCTAssertEqual(name, "temperature")
  }

  func testTemperatureRejectionPhrasings() {
    let phrasings = [
      "Unsupported value: 'temperature' does not support 0.7 with this model.",
      "Unsupported parameter: 'temperature' is not supported with this model.",
      "`temperature` is deprecated for this model.",
      "This model does not support temperature.",
    ]
    for phrasing in phrasings {
      let json = #"{"error":{"message":"\#(phrasing)"}}"#
      let error = GatewayFailureMapper.error(status: 400, body: body(json))
      guard case .unsupportedParameter = error else {
        return XCTFail("should have been read as a temperature rejection: \(phrasing)")
      }
    }
  }

  /// A 400 that merely mentions the word must not trigger the retry.
  func testUnrelatedBadRequestMentioningTemperatureIsNotARejection() {
    let error = GatewayFailureMapper.error(
      status: 400,
      body: body(#"{"error":{"message":"temperature must be between 0 and 2"}}"#))
    guard case .apiError = error else {
      return XCTFail("expected apiError, got \(error)")
    }
  }

  func testTemperatureRejectionOnlyAppliesTo400() {
    let error = GatewayFailureMapper.error(
      status: 500,
      body: body(#"{"error":{"message":"Unsupported parameter: temperature"}}"#))
    guard case .apiError = error else {
      return XCTFail("a 500 is not a parameter rejection, got \(error)")
    }
  }
}

final class GatewayModelInfoTests: XCTestCase {

  private func model(_ id: String) -> GatewayModelInfo {
    GatewayModelInfo(id: id, ownedBy: nil, supportsVision: nil, contextWindow: nil)
  }

  func testImageModelsAreRoutedToTheImageEndpoint() {
    XCTAssertTrue(model("gpt-image-1").isImageGeneration)
    XCTAssertTrue(model("imagen-3.0-generate").isImageGeneration)
  }

  func testTextModelsAreNot() {
    XCTAssertFalse(model("gpt-4o").isImageGeneration)
    XCTAssertFalse(model("claude-opus-4").isImageGeneration)
  }

  /// Embedding models report a zero context window like image models do, so they
  /// are excluded explicitly rather than by shape.
  func testEmbeddingModelsAreNotTreatedAsImageModels() {
    XCTAssertFalse(model("text-embedding-3-large").isImageGeneration)
    XCTAssertFalse(model("multimodal-image-embedding-001").isImageGeneration)
  }
}
