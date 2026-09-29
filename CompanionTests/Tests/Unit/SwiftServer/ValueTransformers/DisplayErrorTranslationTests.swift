/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
import FBSimulatorControl
import GRPCCore
import XCTest

/// Pins the status each display error reaches a client as. The HID stream, `accessibility_info` and
/// `list_displays` all report through this one table, so a display fails the same way whichever command
/// named it, and none of these reaches the client as an internal error.
final class DisplayErrorTranslationTests: XCTestCase {

  func testEveryDisplayErrorHasTheStatusOfItsCause() {
    let expected: [(any Error, RPCError.Code)] = [
      // The caller's mistake: an id the simulator does not have, a point off the display, or a backend
      // that cannot read the display named.
      (SimulatorDisplayError.unknownDisplay("x", known: ["y"]), .invalidArgument),
      (SimulatorDisplayInteractionError.invalidPoint, .invalidArgument),
      (UIAutomationError.operationUnsupported(backend: .accessibility, operation: "x"), .invalidArgument),
      // The device's state: the display exists, but cannot be used as asked right now.
      (SimulatorDisplayError.inactiveDisplay("x"), .failedPrecondition),
      (SimulatorDisplayError.noTouchscreen("x"), .failedPrecondition),
      (SimulatorDisplayError.noActiveIntegratedDisplay, .failedPrecondition),
      (SimulatorDisplayError.ambiguousActiveDisplays(["x", "y"]), .failedPrecondition),
      (SimulatorDisplayError.changed, .failedPrecondition),
      (SimulatorDisplayError.screensNotReported(within: 1), .failedPrecondition),
      (SimulatorDisplayInteractionError.inactiveDisplay("x"), .failedPrecondition),
      (SimulatorDisplayInteractionError.missingMapping("x"), .failedPrecondition),
      // What this simulator, runtime or transport can never do.
      (SimulatorDisplayError.touchRoutingUnsupported("x"), .unimplemented),
      (SimulatorDisplayInteractionError.unsupportedCapability("x"), .unimplemented),
      (SimulatorHIDError.touchUnsupportedOnAppleTV, .unimplemented),
      (SimulatorHIDError.touchTargetUnsupportedOnIndigoTransport(displayUniqueID: "x"), .unimplemented),
      (IDBCommandError.displayIdUnreported(displayUniqueID: "x"), .unimplemented),
    ]
    for (error, code) in expected {
      let status = DisplayErrorTranslation.status(for: error)
      XCTAssertEqual(status?.code, code, "\(error)")
      XCTAssertEqual(status?.message, error.localizedDescription, "the status carries the error's own message")
    }
  }

  func testOtherErrorsAreLeftForErrorMapping() {
    let unrelated: [any Error] = [
      SimulatorHIDError.clientDisposed,
      IDBCommandError.noDebugServer,
      RPCError(code: .aborted, message: "x"),
    ]
    for error in unrelated {
      XCTAssertNil(DisplayErrorTranslation.status(for: error), "\(error)")
    }
  }

  func testTranslatingRethrowsADisplayErrorAsItsStatus() async {
    do {
      try await DisplayErrorTranslation.translatingErrors { () async throws -> Void in
        throw SimulatorDisplayError.unknownDisplay("x", known: ["y"])
      }
      XCTFail("expected the display error to be rethrown")
    } catch let error as RPCError {
      XCTAssertEqual(error.code, .invalidArgument)
    } catch {
      XCTFail("expected an RPCError, got \(error)")
    }
  }

  func testTranslatingRethrowsOtherErrorsUntouched() async {
    do {
      try await DisplayErrorTranslation.translatingErrors { () async throws -> Void in
        throw SimulatorHIDError.clientDisposed
      }
      XCTFail("expected the HID error to be rethrown")
    } catch SimulatorHIDError.clientDisposed {
    } catch {
      XCTFail("expected the HID error untouched, got \(error)")
    }
  }
}
