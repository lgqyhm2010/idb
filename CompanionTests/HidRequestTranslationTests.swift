/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
import CoreGraphics
import FBSimulatorControl
import GRPCCore
import IDBGRPCSwift
import XCTest

final class HidRequestTranslationTests: XCTestCase {
  func testHingeAnglesSurviveTheWire() throws {
    for degrees in [0.0, 90.0, 135.5, 180.0] {
      let request = Idb_HIDEvent.with { $0.hinge.angle = degrees }
      guard case let .hinge(angle) = try HidMethodHandler.fbSimulatorHIDEvent(from: request) else {
        return XCTFail("Expected hinge input")
      }
      XCTAssertEqual(angle.degrees, degrees)
    }
  }

  func testInvalidAnglesAreInvalidArguments() {
    for degrees in [-1, 180.001, Double.nan, .infinity, -.infinity] {
      let request = Idb_HIDEvent.with { $0.hinge.angle = degrees }
      XCTAssertThrowsError(try HidMethodHandler.fbSimulatorHIDEvent(from: request)) { error in
        XCTAssertEqual((error as? RPCError)?.code, .invalidArgument)
      }
    }
  }

  func testDisplaySelectionNamesADisplayOrTheActiveOne() {
    XCTAssertEqual(HidMethodHandler.displayUniqueID(from: .with { $0.uniqueID = "inner" }), "inner")
    XCTAssertNil(HidMethodHandler.displayUniqueID(from: .init()))
  }

  func testDisplaySelectionIsNotItselfAnEvent() {
    let request = Idb_HIDEvent.with { $0.display.uniqueID = "inner" }
    XCTAssertThrowsError(try HidMethodHandler.fbSimulatorHIDEvent(from: request)) { error in
      XCTAssertEqual((error as? RPCError)?.code, .invalidArgument)
    }
  }

  // A rotation or a fold moves the display under a resolved target, so the selection is resolved again
  // before the next touch, and not before events that have no display.
  func testASelectionIsResolvedAgainBeforeTheFirstTouchAfterARotationOrAFold() throws {
    let fold = SimulatorHIDEvent.hinge(try SimulatorHingeAngle(degrees: 0))
    for change in [SimulatorHIDEvent.deviceOrientation(.landscapeLeft), fold] {
      var routing = HidMethodHandler.TouchRouting()
      routing.select(.with { $0.uniqueID = "inner" }, target: innerTarget)
      XCTAssertNil(routing.selectionToResolve(before: tap))
      routing.sent(change)
      XCTAssertNil(routing.selectionToResolve(before: .keyboard(direction: .down, keyCode: 4)))
      XCTAssertEqual(routing.selectionToResolve(before: tap)?.uniqueID, "inner")
      routing.resolved(innerTarget)
      XCTAssertNil(routing.selectionToResolve(before: tap))
    }
  }

  // A contact goes to one touchscreen from its start to its end, so a rotation while it is down waits
  // for it to lift before the target moves.
  func testASelectionIsNotResolvedAgainWhileATouchIsDown() {
    var routing = HidMethodHandler.TouchRouting()
    routing.select(.with { $0.uniqueID = "inner" }, target: innerTarget)
    routing.sent(.touch(direction: .down, x: 1, y: 1))
    XCTAssertTrue(routing.touchIsDown)
    routing.sent(.deviceOrientation(.landscapeLeft))
    let lift = SimulatorHIDEvent.touch(direction: .up, x: 1, y: 1)
    XCTAssertNil(routing.selectionToResolve(before: lift))
    routing.sent(lift)
    XCTAssertFalse(routing.touchIsDown)
    XCTAssertNotNil(routing.selectionToResolve(before: tap))
  }

  func testWithoutASelectionNothingIsResolved() {
    var routing = HidMethodHandler.TouchRouting()
    routing.sent(.deviceOrientation(.landscapeLeft))
    XCTAssertNil(routing.selectionToResolve(before: tap))
    XCTAssertNil(routing.target)
  }

  private let tap = SimulatorHIDEvent.composite([
    .touch(direction: .down, x: 1, y: 1),
    .touch(direction: .up, x: 1, y: 1),
  ])

  private let innerTarget = SimulatorTouchTarget(
    displayUniqueID: "inner", digitizerTarget: 2, pixelSize: CGSize(width: 2007, height: 2853), scale: 3)

  func testUnknownDisplayIsTheCallersMistakeAndTheRestAreDeviceState() {
    XCTAssertEqual(HidMethodHandler.rpcCode(for: .unknownDisplay("x", known: [])), .invalidArgument)
    XCTAssertEqual(HidMethodHandler.rpcCode(for: .inactiveDisplay("x")), .failedPrecondition)
    XCTAssertEqual(HidMethodHandler.rpcCode(for: .noTouchscreen("x")), .failedPrecondition)
    XCTAssertEqual(HidMethodHandler.rpcCode(for: .noActiveIntegratedDisplay), .failedPrecondition)
  }

  // A runtime or target that cannot route touches by display never will, however often it is asked.
  func testDisplayRoutingThatCannotWorkHereIsUnimplemented() {
    XCTAssertEqual(HidMethodHandler.rpcCode(for: .touchRoutingUnsupported("x")), .unimplemented)
    XCTAssertEqual(HidMethodHandler.rpcCode(forHIDError: .touchUnsupportedOnAppleTV), .unimplemented)
  }
}
