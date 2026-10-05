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
      guard case let .hinge(angle) = try HidMethodHandler.request(from: request) else {
        return XCTFail("Expected a hinge request")
      }
      XCTAssertEqual(angle.degrees, degrees)
    }
  }

  func testInvalidAnglesAreInvalidArguments() {
    for degrees in [-1, 180.001, Double.nan, .infinity, -.infinity] {
      let request = Idb_HIDEvent.with { $0.hinge.angle = degrees }
      XCTAssertThrowsError(try HidMethodHandler.request(from: request)) { error in
        XCTAssertEqual((error as? RPCError)?.code, .invalidArgument)
      }
    }
  }

  func testOrientationsKeepTheirNamesOnTheWire() throws {
    let expected: [(Idb_HIDEvent.HIDOrientationType, SimulatorHIDDeviceOrientation)] = [
      (.portrait, .portrait),
      (.portraitUpsideDown, .portraitUpsideDown),
      (.landscapeLeft, .landscapeLeft),
      (.landscapeRight, .landscapeRight),
    ]
    for (wire, orientation) in expected {
      let request = Idb_HIDEvent.with { $0.orientation.orientation = wire }
      XCTAssertEqual(try HidMethodHandler.request(from: request), .orientation(orientation))
    }
  }

  func testAnUnrecognizedOrientationIsAnInvalidArgument() {
    let request = Idb_HIDEvent.with { $0.orientation.orientation = .UNRECOGNIZED(99) }
    XCTAssertThrowsError(try HidMethodHandler.request(from: request)) { error in
      XCTAssertEqual((error as? RPCError)?.code, .invalidArgument)
    }
  }

  func testButtonsKeepTheirNamesOnTheWire() throws {
    let expected: [(Idb_HIDEvent.HIDButtonType, SimulatorHIDButton)] = [
      (.applePay, .applePay),
      (.home, .homeButton),
      (.lock, .lock),
      (.sideButton, .sideButton),
      (.siri, .siri),
      (.playPause, .playPause),
      (.volumeUp, .volumeUp),
      (.volumeDown, .volumeDown),
      (.eject, .eject),
    ]
    for (wire, button) in expected {
      for (wireDirection, direction) in [(Idb_HIDEvent.HIDDirection.down, SimulatorHIDDirection.down), (.up, .up)] {
        let request = Idb_HIDEvent.with {
          $0.press.action.button.button = wire
          $0.press.direction = wireDirection
        }
        XCTAssertEqual(try HidMethodHandler.request(from: request), .input(.button(direction: direction, button: button)))
      }
    }
  }

  func testAnUnrecognizedButtonIsAnInvalidArgument() {
    let request = Idb_HIDEvent.with { $0.press.action.button.button = .UNRECOGNIZED(99) }
    XCTAssertThrowsError(try HidMethodHandler.request(from: request)) { error in
      XCTAssertEqual((error as? RPCError)?.code, .invalidArgument)
    }
  }

  func testShakeTranslatesToShake() throws {
    let request = Idb_HIDEvent.with { $0.shake = Idb_HIDEvent.HIDShake() }
    XCTAssertEqual(try HidMethodHandler.request(from: request), .shake)
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
      try HidMethodHandler.request(from: request, edge: .bottom),
      .input(.touch(direction: .down, x: 10, y: 20, edge: .bottom)))
    XCTAssertEqual(
      try HidMethodHandler.request(from: request),
      .input(.touch(direction: .down, x: 10, y: 20, edge: .none)),
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
    guard case let .input(swipe) = try HidMethodHandler.request(from: request, edge: .bottom) else {
      return XCTFail("Expected swipe input")
    }
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
    XCTAssertThrowsError(try HidMethodHandler.request(from: request)) { error in
      XCTAssertEqual((error as? RPCError)?.code, .invalidArgument)
    }
  }


  func testStreamDefaultsToActiveAndSelectionsAreLocal() throws {
    var first = HidMethodHandler.StreamRouting()
    XCTAssertEqual(first.binding, .active)
    try first.select(.with { $0.uniqueID = "inner" })
    XCTAssertEqual(first.binding, .display(uniqueID: "inner"))
    XCTAssertEqual(HidMethodHandler.StreamRouting().binding, .active)
    try first.select(.init())
    XCTAssertEqual(first.binding, .active)
  }

  func testStreamCannotSwitchOrRotateWithAContactDown() throws {
    var routing = HidMethodHandler.StreamRouting()
    routing.sent(.touch(direction: .down, x: 1, y: 2))
    XCTAssertThrowsError(try routing.select(.with { $0.uniqueID = "cover" }))
    XCTAssertThrowsError(try routing.requireLiftedContacts())
    XCTAssertEqual(routing.binding, .active)
    routing.sent(.touch(direction: .up, x: 1, y: 2))
    try routing.requireLiftedContacts()
    try routing.select(.with { $0.uniqueID = "cover" })
    XCTAssertEqual(routing.binding, .display(uniqueID: "cover"))
  }

  func testCompletePinchAllowsNextSelection() throws {
    var routing = HidMethodHandler.StreamRouting()
    routing.sent(.pinchAt(x: 100, y: 100, scale: 0.5, duration: 0.1, radius: 10))
    XCTAssertFalse(routing.twoFingersAreDown)
    try routing.select(.init())
  }

  func testSelectorsAreNotPrimitiveEvents() {
    for request: Idb_HIDEvent in [.with { $0.display.uniqueID = "inner" }, .with { $0.edge.edge = .edgeTop }] {
      XCTAssertThrowsError(try HidMethodHandler.request(from: request)) { error in
        XCTAssertEqual((error as? RPCError)?.code, .invalidArgument)
      }
    }
  }
}
