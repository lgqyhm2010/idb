/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
@preconcurrency import FBControlCore
import FBSimulatorControl
import GRPCCore
import IDBGRPCSwift
import XCTest

/// Records the options the handler hands the command executor, so a test can read them without a
/// simulator. `IDBCommandExecutor` is a `public final class`; `AccessibilityDescribing` is the seam
/// the handler is written against, and this double stands in for it.
private final class RecordingAccessibilityExecutor: AccessibilityDescribing {
  private(set) var describeOptions: AccessibilityRequestOptions?
  private(set) var describeQuery: AccessibilityElementQuery?
  private(set) var pointReadCount = 0
  private(set) var applicationReads: [String] = []
  private(set) var applicationBackend: UIAutomationBackend?

  func accessibility_describe(
    query: AccessibilityElementQuery,
    options: AccessibilityRequestOptions,
    backend: UIAutomationBackend
  ) async throws -> Data {
    describeQuery = query
    describeOptions = options
    return Data("{}".utf8)
  }

  func accessibility_info_at_point(
    _ value: NSValue?,
    options: AccessibilityRequestOptions,
    backend: UIAutomationBackend
  ) async throws -> AccessibilityElementsResponse {
    pointReadCount += 1
    return AccessibilityElementsResponse(elements: .single(AccessibilityDocumentElement()))
  }

  func accessibility_info_for_application(
    bundleID: String,
    options: AccessibilityRequestOptions,
    backend: UIAutomationBackend
  ) async throws -> AccessibilityElementsResponse {
    applicationReads.append(bundleID)
    applicationBackend = backend
    return AccessibilityElementsResponse(elements: .single(AccessibilityDocumentElement()))
  }
}

/// Asserts what the *handler* hands the executor, which is where a describe-by-marker can silently
/// lose the request's `--key`/`--profile`/`--collect-frame-coverage` by reaching the executor with a
/// format-only options set. `AccessibilityInfoRequestTranslation.options(from:)` carries them for
/// both paths, so coverage on that translation alone does not guard the marker path.
final class AccessibilityInfoMethodHandlerTests: XCTestCase {

  func testMarkerReadCarriesTheRequestedKeysToTheExecutor() async throws {
    let executor = RecordingAccessibilityExecutor()
    var request = Idb_AccessibilityInfoRequest()
    request.marker = "OK"
    request.keys = ["AXLabel"]

    _ = try await AccessibilityInfoMethodHandler.respond(to: request, using: executor)

    let options = try XCTUnwrap(
      executor.describeOptions, "a marker read must reach the describe executor, not the at-point path")
    let label = try XCTUnwrap(AXKeys(rawValue: "AXLabel"))
    XCTAssertEqual(
      options.keys, Set([label]),
      "the request's --key must reach the executor on the marker path, not a format-only default set")
    XCTAssertEqual(executor.pointReadCount, 0, "a marker read must not fall through to the at-point read")
  }

  func testMarkerReadCarriesProfilingAndFrameCoverageToTheExecutor() async throws {
    let executor = RecordingAccessibilityExecutor()
    var request = Idb_AccessibilityInfoRequest()
    request.marker = "OK"
    request.profile = true
    request.collectFrameCoverage = true

    _ = try await AccessibilityInfoMethodHandler.respond(to: request, using: executor)

    let options = try XCTUnwrap(executor.describeOptions)
    XCTAssertTrue(options.enableProfiling, "--profile is a read option and a marker read is a read")
    XCTAssertTrue(
      options.collectFrameCoverage, "--collect-frame-coverage is a read option and a marker read is a read")
  }

  func testBundleIDReadsThatApplicationInsteadOfTheFrontmostOne() async throws {
    let executor = RecordingAccessibilityExecutor()
    var request = Idb_AccessibilityInfoRequest()
    request.bundleID = "com.example.app"

    _ = try await AccessibilityInfoMethodHandler.respond(to: request, using: executor)

    XCTAssertEqual(executor.applicationReads, ["com.example.app"])
    XCTAssertEqual(
      executor.pointReadCount, 0,
      "with two apps on screen the frontmost read may describe the other one, so it must not be used")
    XCTAssertEqual(
      executor.applicationBackend, AccessibilityInfoRequestTranslation.backend(from: .axbridge),
      "the CoreSimulator backend cannot read an app by pid, so an unset backend must mean the bridge")
  }

  func testBundleIDWithTheAXBackendIsRefusedBeforeAnyRead() async throws {
    let executor = RecordingAccessibilityExecutor()
    var request = Idb_AccessibilityInfoRequest()
    request.bundleID = "com.example.app"
    request.backend = .ax

    do {
      _ = try await AccessibilityInfoMethodHandler.respond(to: request, using: executor)
      XCTFail("the ax backend answers a pid read with a message blaming a point the caller never gave")
    } catch let error as RPCError {
      XCTAssertEqual(error.code, .invalidArgument)
    }
    XCTAssertEqual(executor.applicationReads, [])
  }

  func testBundleIDBesideAPointIsRefusedBeforeAnyRead() async throws {
    let executor = RecordingAccessibilityExecutor()
    var request = Idb_AccessibilityInfoRequest()
    request.bundleID = "com.example.app"
    request.point = .with {
      $0.x = 10
      $0.y = 10
    }

    do {
      _ = try await AccessibilityInfoMethodHandler.respond(to: request, using: executor)
      XCTFail("a point names an element in whatever is frontmost, which may not be the named app")
    } catch let error as RPCError {
      XCTAssertEqual(error.code, .invalidArgument)
    }
    XCTAssertEqual(executor.applicationReads, [])
    XCTAssertEqual(executor.pointReadCount, 0)
  }
}
