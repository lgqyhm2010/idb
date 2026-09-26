/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
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

  func testUnknownDisplayIsTheCallersMistakeAndTheRestAreDeviceState() {
    XCTAssertEqual(HidMethodHandler.rpcCode(for: .unknownDisplay("x", known: [])), .invalidArgument)
    XCTAssertEqual(HidMethodHandler.rpcCode(for: .inactiveDisplay("x")), .failedPrecondition)
    XCTAssertEqual(HidMethodHandler.rpcCode(for: .noTouchscreen("x")), .failedPrecondition)
    XCTAssertEqual(HidMethodHandler.rpcCode(for: .noActiveIntegratedDisplay), .failedPrecondition)
  }

  func testEdgeSelectionTagsTouches() throws {
    let request = Idb_HIDEvent.with {
      $0.press.action.touch.point = .with {
        $0.x = 10
        $0.y = 20
      }
      $0.press.direction = .down
    }
    XCTAssertEqual(
      try HidMethodHandler.fbSimulatorHIDEvent(from: request, edge: .bottom),
      .touch(direction: .down, x: 10, y: 20, edge: .bottom))
    XCTAssertEqual(
      try HidMethodHandler.fbSimulatorHIDEvent(from: request),
      .touch(direction: .down, x: 10, y: 20, edge: .none),
      "without a selection a touch is an ordinary one")
  }

  func testEdgeSelectionTagsEverySampleOfASwipe() throws {
    let request = Idb_HIDEvent.with {
      $0.swipe.start = .with {
        $0.x = 100
        $0.y = 400
      }
      $0.swipe.end = .with {
        $0.x = 100
        $0.y = 200
      }
      $0.swipe.delta = 50
      $0.swipe.duration = 0.2
    }
    let swipe = try HidMethodHandler.fbSimulatorHIDEvent(from: request, edge: .bottom)
    let touches = try XCTUnwrap(swipe.subEvents).compactMap { event -> SimulatorHIDEdge? in
      guard case let .touch(_, _, _, edge) = event else { return nil }
      return edge
    }
    XCTAssertFalse(touches.isEmpty)
    XCTAssertEqual(
      Set(touches), [.bottom],
      "the guest reads the flag off whichever contact it inspects, so an untagged sample breaks the gesture")
  }

  func testEdgeTypesMapOneToOne() throws {
    XCTAssertEqual(try HidMethodHandler.fbSimulatorHIDEdge(from: .edgeNone), SimulatorHIDEdge.none)
    XCTAssertEqual(try HidMethodHandler.fbSimulatorHIDEdge(from: .edgeTop), .top)
    XCTAssertEqual(try HidMethodHandler.fbSimulatorHIDEdge(from: .edgeLeft), .left)
    XCTAssertEqual(try HidMethodHandler.fbSimulatorHIDEdge(from: .edgeBottom), .bottom)
    XCTAssertEqual(try HidMethodHandler.fbSimulatorHIDEdge(from: .edgeRight), .right)
    XCTAssertThrowsError(try HidMethodHandler.fbSimulatorHIDEdge(from: .UNRECOGNIZED(9))) { error in
      XCTAssertEqual((error as? RPCError)?.code, .invalidArgument)
    }
  }

  func testEdgeSelectionIsNotItselfAnEvent() {
    let request = Idb_HIDEvent.with { $0.edge.edge = .edgeBottom }
    XCTAssertThrowsError(try HidMethodHandler.fbSimulatorHIDEvent(from: request)) { error in
      XCTAssertEqual((error as? RPCError)?.code, .invalidArgument)
    }
  }

  // A runtime or target that cannot route touches by display never will, however often it is asked.
  func testDisplayRoutingThatCannotWorkHereIsUnimplemented() {
    XCTAssertEqual(HidMethodHandler.rpcCode(for: .touchRoutingUnsupported("x")), .unimplemented)
    XCTAssertEqual(HidMethodHandler.rpcCode(forHIDError: .touchUnsupportedOnAppleTV), .unimplemented)
  }
}
