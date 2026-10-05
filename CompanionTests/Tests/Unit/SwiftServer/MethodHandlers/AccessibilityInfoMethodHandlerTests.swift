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
    describeOptions = options
    applicationReads.append(bundleID)
    applicationBackend = backend
    return AccessibilityElementsResponse(elements: .single(AccessibilityDocumentElement()))
  }

  private(set) var displayReads: [(point: CGPoint, display: String?)] = []
  /// Thrown by a read on a display, as the executor throws when it cannot resolve the display named.
  var displayReadError: (any Error)?

  func accessibility_info_at_point(
    _ point: CGPoint,
    onDisplay displayUniqueID: String?,
    options: AccessibilityRequestOptions,
    backend: UIAutomationBackend
  ) async throws -> AccessibilityElementsResponse {
    describeOptions = options
    displayReads.append((point, displayUniqueID))
    if let displayReadError {
      throw displayReadError
    }
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

  func testBundleAndDisplayReadsPreserveReadOptions() async throws {
    for application in [true, false] {
      let executor = RecordingAccessibilityExecutor()
      var request = Idb_AccessibilityInfoRequest()
      request.profile = true
      request.collectFrameCoverage = true
      request.keys = ["AXLabel"]
      request.filter = .interactable
      request.match = "OK"
      request.ignoreCase = true
      if application {
        request.bundleID = "com.example.app"
      } else {
        request.point = .with { $0.x = 12; $0.y = 34 }
        request.display = .with { $0.uniqueID = "inner" }
      }
      _ = try await AccessibilityInfoMethodHandler.respond(to: request, using: executor)
      let options = try XCTUnwrap(executor.describeOptions)
      XCTAssertTrue(options.enableProfiling)
      XCTAssertTrue(options.collectFrameCoverage)
      XCTAssertEqual(options.keys, [.label])
      XCTAssertEqual(options.filter, .interactable)
      XCTAssertNotNil(options.match)
    }
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

  func testAPointOnADisplayIsHitTestedThere() async throws {
    let executor = RecordingAccessibilityExecutor()
    var request = Idb_AccessibilityInfoRequest()
    request.point = .with {
      $0.x = 251
      $0.y = 300
    }
    request.display = .with { $0.uniqueID = "inner" }

    _ = try await AccessibilityInfoMethodHandler.respond(to: request, using: executor)

    XCTAssertEqual(executor.displayReads.map(\.display), ["inner"])
    XCTAssertEqual(executor.displayReads.first?.point, CGPoint(x: 251, y: 300))
    XCTAssertEqual(executor.pointReadCount, 0, "the main screen is dark on an unfolded foldable")
  }

  func testADisplayWithoutAPointIsRefused() async throws {
    let executor = RecordingAccessibilityExecutor()
    var request = Idb_AccessibilityInfoRequest()
    request.display = .with { $0.uniqueID = "" }

    do {
      _ = try await AccessibilityInfoMethodHandler.respond(to: request, using: executor)
      XCTFail("a display with no point names nothing to hit-test")
    } catch let error as RPCError {
      XCTAssertEqual(error.code, .invalidArgument)
    }
    XCTAssertEqual(executor.pointReadCount + executor.displayReads.count, 0)
  }

  func testADisplayBesideAMarkerIsRefusedBeforeAnyRead() async throws {
    let executor = RecordingAccessibilityExecutor()
    var request = Idb_AccessibilityInfoRequest()
    request.marker = "OK"
    request.point = .with {
      $0.x = 251
      $0.y = 300
    }
    request.display = .with { $0.uniqueID = "inner" }

    do {
      _ = try await AccessibilityInfoMethodHandler.respond(to: request, using: executor)
      XCTFail("a marker finds its element wherever it is, so the display would be silently ignored")
    } catch let error as RPCError {
      XCTAssertEqual(error.code, .invalidArgument)
    }
    XCTAssertNil(executor.describeQuery)
    XCTAssertEqual(executor.pointReadCount + executor.displayReads.count, 0)
  }

  func testAnUnknownDisplayIsTheCallersMistake() async throws {
    let executor = RecordingAccessibilityExecutor()
    let unknown = SimulatorDisplayError.unknownDisplay("outer", known: ["inner"])
    executor.displayReadError = unknown
    var request = Idb_AccessibilityInfoRequest()
    request.point = .with {
      $0.x = 251
      $0.y = 300
    }
    request.display = .with { $0.uniqueID = "outer" }

    do {
      _ = try await AccessibilityInfoMethodHandler.respond(to: request, using: executor)
      XCTFail("the simulator has no display outer")
    } catch let error as RPCError {
      XCTAssertEqual(error.code, .invalidArgument, "an id the simulator does not have is not an internal error")
      XCTAssertEqual(error.message, unknown.localizedDescription)
    }
  }

  func testABackendThatCannotReadTheDisplayNamedIsTheCallersMistake() async throws {
    let executor = RecordingAccessibilityExecutor()
    // What the executor raises once the display report shows the display named is not the main screen.
    let unsupported = UIAutomationError.operationUnsupported(
      backend: AccessibilityInfoRequestTranslation.backend(from: .axbridge),
      operation: "Describing a point on another display")
    executor.displayReadError = unsupported
    var request = Idb_AccessibilityInfoRequest()
    request.point = .with {
      $0.x = 251
      $0.y = 300
    }
    request.display = .with { $0.uniqueID = "inner" }
    request.backend = .axbridge

    do {
      _ = try await AccessibilityInfoMethodHandler.respond(to: request, using: executor)
      XCTFail("any display but the device's only integrated one is read by the AX backend only")
    } catch let error as RPCError {
      XCTAssertEqual(
        error.code, .invalidArgument, "a backend the caller chose is not an internal error, as with a bundle id")
      XCTAssertEqual(error.message, unsupported.localizedDescription)
    }
  }

  func testADisplayThatCannotBeHitTestedIsTheDevicesState() async throws {
    let executor = RecordingAccessibilityExecutor()
    executor.displayReadError = SimulatorDisplayInteractionError.inactiveDisplay("outer")
    var request = Idb_AccessibilityInfoRequest()
    request.point = .with {
      $0.x = 251
      $0.y = 300
    }
    request.display = .with { $0.uniqueID = "outer" }

    do {
      _ = try await AccessibilityInfoMethodHandler.respond(to: request, using: executor)
      XCTFail("nothing is lit on outer to hit-test")
    } catch let error as RPCError {
      XCTAssertEqual(error.code, .failedPrecondition)
    }
  }
}
