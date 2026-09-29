/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBSimulatorControl
import Foundation
import XCTest
@preconcurrency import XPC

/// A display record. A nil `id` or `active` leaves the field out, as legacy and backlight-only providers do.
private func displayValue(
  id: String?, active: Bool?, primary: Bool = false, rotation: String = "rot0", displayId: UInt64? = nil,
  backlight: String? = nil, type: String = "integrated"
) -> xpc_object_t {
  let dictionary = SimulatorCoreDevice.dictionary
  let array = SimulatorCoreDevice.array
  let value = dictionary([
    "name": xpc_string_create(id ?? type), "primary": xpc_bool_create(primary),
    "bounds": array([array([xpc_double_create(0), xpc_double_create(0)]), array([xpc_double_create(2007), xpc_double_create(2853)])]),
    "pointScale": xpc_int64_create(3), "currentOrientation": xpc_string_create(rotation),
    "type": dictionary([type: dictionary([:])]),
  ])
  if let id {
    xpc_dictionary_set_string(value, "uniqueId", id)
  }
  if let active {
    xpc_dictionary_set_bool(value, "active", active)
  }
  if let displayId {
    xpc_dictionary_set_uint64(value, "displayId", displayId)
  }
  if let backlight {
    xpc_dictionary_set_string(value, "backlightState", backlight)
  }
  return value
}

private func displayReply(_ values: [xpc_object_t], current: Bool = true) -> xpc_object_t {
  SimulatorCoreDevice.dictionary([
    "CoreDevice.output": SimulatorCoreDevice.dictionary([
      "current": xpc_bool_create(current), "displays": SimulatorCoreDevice.array(values),
    ])
  ])
}

final class SimulatorDisplayReadTests: XCTestCase {
  func testLegacyGeometryRetainsInterfaceRotationWithoutInventingIdentity() throws {
    let value = displayValue(id: "legacy", active: true, rotation: "rot90")
    xpc_dictionary_set_value(value, "active", nil)
    xpc_dictionary_set_value(value, "uniqueId", nil)
    let selected = try SimulatorDisplayProtocol.interactionDisplay(displayReply([value]))
    guard case let .legacy(geometry) = selected else { return XCTFail("Expected legacy geometry") }
    XCTAssertEqual(geometry.pointSize, CGSize(width: 951, height: 669))
    XCTAssertEqual(try geometry.unrotatedPoint(from: CGPoint(x: 787, y: 570)), CGPoint(x: 570, y: 164))
    XCTAssertThrowsError(try SimulatorDisplayProtocol.interactionDisplay(displayReply([value, value])))
    XCTAssertThrowsError(try SimulatorDisplayProtocol.interactionDisplay(displayReply([value], current: false)))
    xpc_dictionary_set_string(value, "uniqueId", "partial")
    XCTAssertThrowsError(try SimulatorDisplayProtocol.interactionDisplay(displayReply([value])))
  }

  func testIdentifiedGeometryUsesActiveDisplayInsteadOfPrimary() throws {
    let selected = try SimulatorDisplayProtocol.interactionDisplay(
      displayReply([
        displayValue(id: "cover", active: false, primary: true),
        displayValue(id: "inner", active: true, rotation: "rot90"),
      ]))
    guard case let .identified(display) = selected else { return XCTFail("Expected identified display") }
    XCTAssertEqual(display.uniqueID, "inner")
    XCTAssertEqual(selected.geometry.pointSize, CGSize(width: 951, height: 669))
  }

  func testOnlySeveralIntegratedDisplaysSelectOneByName() throws {
    let sole = try SimulatorDisplayProtocol.interactionTarget(displayReply([displayValue(id: "lcd", active: true)]))
    guard case let .sole(.identified(lcd)) = sole else { return XCTFail("Expected the sole identified display") }
    XCTAssertEqual(lcd.uniqueID, "lcd")

    let selected = try SimulatorDisplayProtocol.interactionTarget(
      displayReply([displayValue(id: "cover", active: false), displayValue(id: "inner", active: true)]))
    guard case let .selected(inner) = selected else { return XCTFail("Expected a selected display") }
    XCTAssertEqual(inner.uniqueID, "inner")

    let legacy = displayValue(id: "legacy", active: true)
    xpc_dictionary_set_value(legacy, "active", nil)
    xpc_dictionary_set_value(legacy, "uniqueId", nil)
    guard case .sole(.legacy) = try SimulatorDisplayProtocol.interactionTarget(displayReply([legacy])) else {
      return XCTFail("Expected the sole legacy display")
    }
  }

  func testInterfacePointConversionPreservesAllFourRotations() throws {
    let cases: [(SimulatorDisplayRotation, CGPoint, CGPoint)] = [
      (.upright, CGPoint(x: 80, y: 120), CGPoint(x: 80, y: 120)),
      (.clockwise, CGPoint(x: 80, y: 120), CGPoint(x: 120, y: 320)),
      (.upsideDown, CGPoint(x: 80, y: 120), CGPoint(x: 520, y: 280)),
      (.counterclockwise, CGPoint(x: 80, y: 120), CGPoint(x: 480, y: 80)),
    ]
    for (rotation, point, expected) in cases {
      let geometry = SimulatorDisplayGeometry(bounds: CGRect(x: 30, y: 40, width: 1200, height: 800), scale: 2, rotation: rotation)
      XCTAssertEqual(try geometry.unrotatedPoint(from: point), expected)
      for invalid in [CGPoint(x: -1, y: 0), CGPoint(x: 1000, y: 0), CGPoint(x: Double.nan, y: 0)] {
        XCTAssertThrowsError(try geometry.unrotatedPoint(from: invalid))
      }
    }
  }

  func testLegacyReportWithoutIdentityOrActivityDeclinesCaptureCapability() throws {
    let value = displayValue(id: "legacy", active: true)
    xpc_dictionary_set_value(value, "active", nil)
    xpc_dictionary_set_value(value, "uniqueId", nil)
    XCTAssertEqual(try SimulatorDisplayProtocol.snapshot(displayReply([value])), .legacyProvider)
    // Listing it makes up a name; capture and `interactionTarget`, which read `snapshot`, never see it.
    XCTAssertEqual(try SimulatorDisplayProtocol.displays(displayReply([value])).map(\.uniqueID), ["legacy-1"])
    XCTAssertThrowsError(try SimulatorDisplayProtocol.snapshot(displayReply([value], current: false)))
    // A legacy record is still held to the rest of the shape.
    xpc_dictionary_set_int64(value, "pointScale", 0)
    XCTAssertThrowsError(try SimulatorDisplayProtocol.snapshot(displayReply([value])))
  }

  // Measured on iOS 26.2 (iPhone 17 Pro, iPad Pro 11-inch M5): no identity or layout activity, every
  // backlight `unknown`. The one integrated display is the screen; the listing names it without
  // claiming an identity any touchscreen covers.
  func testLegacyReportListsItsSoleIntegratedDisplayAsActive() throws {
    let values = [
      displayValue(id: nil, active: nil, primary: true, displayId: 1, backlight: "unknown"),
      displayValue(id: nil, active: nil, displayId: 2, backlight: "unknown", type: "external"),
      displayValue(id: nil, active: nil, displayId: 3, backlight: "unknown", type: "wireless"),
    ]
    XCTAssertEqual(try SimulatorDisplayProtocol.snapshot(displayReply(values)), .legacyProvider)
    guard case .sole(.legacy) = try SimulatorDisplayProtocol.interactionTarget(displayReply(values)) else {
      return XCTFail("Expected the sole legacy display")
    }
    let displays = try SimulatorDisplayProtocol.displays(displayReply(values))
    XCTAssertEqual(displays.map(\.uniqueID), ["legacy-1", "legacy-2", "legacy-3"])
    XCTAssertEqual(displays.map(\.isActive), [true, false, false])
    XCTAssertEqual(displays.map(\.displayId), [1, 2, 3])
    XCTAssertEqual(displays.map(\.activitySource), [.soleIntegratedDisplay, .soleIntegratedDisplay, .soleIntegratedDisplay])
    XCTAssertEqual(displays.map(\.reportedActivity), [nil, nil, nil])
    XCTAssertEqual(try SimulatorDisplayCommands.activeIntegratedDisplay(in: displays).uniqueID, "legacy-1")
    XCTAssertThrowsError(
      try SimulatorTouchTarget.resolve(displayUniqueID: "legacy-1", displays: displays, touchscreens: [])
    ) { error in
      guard case .noTouchscreen("legacy-1")? = error as? SimulatorDisplayError else {
        return XCTFail("Expected noTouchscreen, got \(error)")
      }
    }
  }

  // A made-up name has to be unique, so a record's displayId names it only when every record has a
  // distinct one; otherwise every record is named by its position.
  func testLegacyNamesNeverCollide() throws {
    for ids: [UInt64?] in [[2, nil, nil], [1, 1, 3], [3, nil, 1]] {
      let values = [
        displayValue(id: nil, active: nil, primary: true, displayId: ids[0], backlight: "unknown"),
        displayValue(id: nil, active: nil, displayId: ids[1], backlight: "unknown", type: "external"),
        displayValue(id: nil, active: nil, displayId: ids[2], backlight: "unknown", type: "wireless"),
      ]
      let displays = try SimulatorDisplayProtocol.displays(displayReply(values))
      XCTAssertEqual(displays.map(\.uniqueID), ["legacy-1", "legacy-2", "legacy-3"], "\(ids)")
      XCTAssertEqual(displays.map(\.displayId), ids.map { id in id.map { UInt32($0) } }, "\(ids)")
      XCTAssertEqual(displays.map(\.isActive), [true, false, false], "\(ids)")
    }
  }

  // When every record has a distinct displayId, that id names it, whatever the record's position.
  func testLegacyNamesTakeDistinctDisplayIds() throws {
    let values = [
      displayValue(id: nil, active: nil, primary: true, displayId: 2, backlight: "unknown"),
      displayValue(id: nil, active: nil, displayId: 3, backlight: "unknown", type: "external"),
      displayValue(id: nil, active: nil, displayId: 1, backlight: "unknown", type: "wireless"),
    ]
    let displays = try SimulatorDisplayProtocol.displays(displayReply(values))
    XCTAssertEqual(displays.map(\.uniqueID), ["legacy-1", "legacy-2", "legacy-3"])
    XCTAssertEqual(displays.map(\.displayId), [1, 2, 3])
    XCTAssertEqual(displays.map(\.isActive), [false, true, false])
    XCTAssertEqual(try SimulatorDisplayCommands.activeIntegratedDisplay(in: displays).uniqueID, "legacy-2")
  }

  func testLegacyReportWithSeveralIntegratedDisplaysIsNotListed() throws {
    let values = [displayValue(id: nil, active: nil, displayId: 1), displayValue(id: nil, active: nil, displayId: 3)]
    XCTAssertEqual(try SimulatorDisplayProtocol.snapshot(displayReply(values)), .legacyProvider)
    XCTAssertThrowsError(try SimulatorDisplayProtocol.displays(displayReply(values))) { error in
      guard case .unsupportedCapability? = error as? SimulatorDisplayInteractionError else {
        return XCTFail("Expected unsupportedCapability, got \(error)")
      }
    }
  }

  // A single-screen device that reports layout activity (iOS 27.1) has a display to select, so it is
  // captured through that display and turned to its interface orientation, not taken as the main
  // framebuffer's unrotated panel.
  func testSoleIntegratedDisplayWithLayoutActivityIsSelectedWithItsRotation() throws {
    let value = displayValue(id: "lcd", active: true, rotation: "rot90", displayId: 1, backlight: "activeOn")
    guard case let .displays(displays) = try SimulatorDisplayProtocol.snapshot(displayReply([value])) else {
      return XCTFail("A report with identity and activity selects a display")
    }
    let selected = try SimulatorDisplayCommands.activeIntegratedDisplay(in: displays)
    XCTAssertEqual(selected.uniqueID, "lcd")
    XCTAssertEqual(selected.rotation, .clockwise)
    XCTAssertEqual(selected.size, CGSize(width: 2853, height: 2007))
    XCTAssertEqual(selected.activitySource, .layout)
  }

  // Measured on iOS 27.0 (iPhone 18 Pro, iPad Pro 11-inch M5): every display identified, none with
  // layout activity, the backlight saying which is lit. The one integrated display is the screen while
  // its backlight is dark or unknown, so listing, capture and interaction all take it then; a missing or
  // unrecognised backlight is still malformed.
  func testSoleIntegratedDisplayIsActiveWhileItsBacklightIsDarkOrUnknown() throws {
    let values = [
      displayValue(id: "lcd", active: nil, primary: true, displayId: 1, backlight: "activeOn"),
      displayValue(id: "tv", active: nil, displayId: 2, backlight: "off", type: "external"),
      displayValue(id: "wireless", active: nil, displayId: 3, backlight: "off", type: "wireless"),
      displayValue(id: "resizable", active: nil, displayId: 4, backlight: "off", type: "virtual"),
    ]
    let cases: [(String, SimulatorDisplayActivitySource)] = [
      ("activeOn", .backlight), ("off", .soleIntegratedDisplay), ("inactiveOn", .soleIntegratedDisplay),
      ("unknown", .soleIntegratedDisplay),
    ]
    for (state, source) in cases {
      xpc_dictionary_set_string(values[0], "backlightState", state)
      let displays = try SimulatorDisplayProtocol.displays(displayReply(values))
      XCTAssertEqual(displays.map(\.uniqueID), ["lcd", "resizable", "tv", "wireless"], state)
      XCTAssertEqual(displays.map(\.isActive), [true, false, false, false], state)
      let lcd = try SimulatorDisplayCommands.activeIntegratedDisplay(in: displays)
      XCTAssertEqual(lcd.activitySource, source, state)
      XCTAssertNil(lcd.reportedActivity, state)
      XCTAssertEqual(lcd.displayId, 1, state)
      XCTAssertEqual(try SimulatorDisplayProtocol.snapshot(displayReply(values)), .displays(displays), state)
      XCTAssertEqual(try SimulatorDisplayProtocol.interactionTarget(displayReply(values)), .sole(.identified(lcd)), state)
    }
    // A missing or unrecognised backlight is still no evidence at all.
    for state in [nil, "futureState"] as [String?] {
      if let state {
        xpc_dictionary_set_string(values[0], "backlightState", state)
      } else {
        xpc_dictionary_set_value(values[0], "backlightState", nil)
      }
      XCTAssertThrowsError(try SimulatorDisplayProtocol.displays(displayReply(values)), "\(String(describing: state))")
      XCTAssertThrowsError(try SimulatorDisplayProtocol.snapshot(displayReply(values)), "\(String(describing: state))")
    }
  }

  // With several integrated displays a dark backlight still means dark: there is no telling which is the screen.
  func testDarkBacklightsOnSeveralIntegratedDisplaysSelectNone() throws {
    let values = [
      displayValue(id: "cover", active: nil, primary: true, backlight: "off"),
      displayValue(id: "inner", active: nil, backlight: "off"),
    ]
    let displays = try SimulatorDisplayProtocol.displays(displayReply(values))
    XCTAssertEqual(displays.map(\.isActive), [false, false])
    XCTAssertEqual(displays.map(\.activitySource), [.backlight, .backlight])
    XCTAssertThrowsError(try SimulatorDisplayProtocol.interactionTarget(displayReply(values))) { error in
      guard case .noActiveIntegratedDisplay? = error as? SimulatorDisplayError else {
        return XCTFail("Expected noActiveIntegratedDisplay, got \(error)")
      }
    }
  }

  func testPartialOrMalformedCaptureCapabilityDoesNotFallBack() {
    XCTAssertThrowsError(try SimulatorDisplayProtocol.snapshot(displayReply([SimulatorCoreDevice.dictionary([:])])))
    let partial = displayValue(id: "inner", active: true)
    xpc_dictionary_set_value(partial, "active", nil)
    XCTAssertThrowsError(try SimulatorDisplayProtocol.snapshot(displayReply([partial])))
    let malformed = displayValue(id: "inner", active: true)
    xpc_dictionary_set_string(malformed, "active", "true")
    XCTAssertThrowsError(try SimulatorDisplayProtocol.snapshot(displayReply([malformed])))
    let legacy = displayValue(id: "legacy", active: true)
    xpc_dictionary_set_value(legacy, "active", nil)
    xpc_dictionary_set_value(legacy, "uniqueId", nil)
    XCTAssertThrowsError(try SimulatorDisplayProtocol.snapshot(displayReply([displayValue(id: "inner", active: true), legacy])))
  }

  func testEmptyCurrentReportDoesNotFallBack() throws {
    guard case let .displays(displays) = try SimulatorDisplayProtocol.snapshot(displayReply([])) else {
      return XCTFail("An empty current report is not a legacy provider")
    }
    XCTAssertThrowsError(try SimulatorDisplayCommands.activeIntegratedDisplay(in: displays))
  }

  func testActivityEvidenceSourceCanChangeWithoutChangingDisplayConfiguration() throws {
    let value = displayValue(id: "inner", active: true, rotation: "rot90")
    xpc_dictionary_set_string(value, "backlightState", "activeOn")
    let layout = try SimulatorDisplayProtocol.interactionDisplay(displayReply([value]))
    xpc_dictionary_set_value(value, "active", nil)
    let backlight = try SimulatorDisplayProtocol.interactionDisplay(displayReply([value]))
    XCTAssertNotEqual(layout, backlight)
    XCTAssertTrue(layout.hasSameConfiguration(as: backlight))
    xpc_dictionary_set_string(value, "currentOrientation", "rot180")
    XCTAssertFalse(layout.hasSameConfiguration(as: try SimulatorDisplayProtocol.interactionDisplay(displayReply([value]))))
  }

  func testCompleteBacklightEvidenceSelectsIlluminatedDisplayWithoutInventingLayoutActivity() throws {
    for state in ["activeOn", "activeDimmed"] {
      let cover = displayValue(id: "cover", active: false, primary: true)
      let inner = displayValue(id: "inner", active: true)
      for value in [cover, inner] { xpc_dictionary_set_value(value, "active", nil) }
      xpc_dictionary_set_string(cover, "backlightState", "off")
      xpc_dictionary_set_string(inner, "backlightState", state)
      let displays = try SimulatorDisplayProtocol.displays(displayReply([cover, inner]))
      let selected = try SimulatorDisplayCommands.activeIntegratedDisplay(in: displays)
      XCTAssertEqual(selected.uniqueID, "inner")
      XCTAssertEqual(selected.activitySource, .backlight)
      XCTAssertNil(selected.reportedActivity)
    }
  }

  func testBacklightSelectionRejectsUncertaintyAmbiguityAndPartialLayoutActivity() throws {
    let cover = displayValue(id: "cover", active: false, primary: true)
    let inner = displayValue(id: "inner", active: true)
    for value in [cover, inner] { xpc_dictionary_set_value(value, "active", nil) }
    for (first, second) in [("off", "off"), ("inactiveOn", "off"), ("unknown", "activeOn"), ("activeOn", "activeDimmed"), ("off", "futureState")] {
      xpc_dictionary_set_string(cover, "backlightState", first)
      xpc_dictionary_set_string(inner, "backlightState", second)
      XCTAssertThrowsError(try SimulatorDisplayProtocol.interactionDisplay(displayReply([cover, inner])))
    }
    xpc_dictionary_set_string(cover, "backlightState", "off")
    xpc_dictionary_set_string(inner, "backlightState", "activeOn")
    xpc_dictionary_set_bool(cover, "active", false)
    XCTAssertThrowsError(try SimulatorDisplayProtocol.displays(displayReply([cover, inner])))
    xpc_dictionary_set_bool(inner, "active", false)
    XCTAssertThrowsError(try SimulatorDisplayProtocol.displays(displayReply([cover, inner])))
    xpc_dictionary_set_bool(inner, "active", true)
    let selected = try SimulatorDisplayCommands.activeIntegratedDisplay(in: SimulatorDisplayProtocol.displays(displayReply([cover, inner])))
    XCTAssertEqual(selected.activitySource, .layout)
    XCTAssertEqual(selected.reportedActivity, true)
  }

  func testDisplayStringsAreBounded() {
    let long = String(repeating: "x", count: 1025)
    for key in ["uniqueId", "name"] {
      let value = displayValue(id: "inner", active: true)
      xpc_dictionary_set_string(value, key, long)
      XCTAssertThrowsError(try SimulatorDisplayProtocol.displays(displayReply([value])), key)
    }
    XCTAssertThrowsError(try SimulatorDisplayProtocol.displays(displayReply([displayValue(id: "", active: true)])))
  }

  func testExplicitActivitySelectsInnerDespiteNonemptyPrimaryBounds() throws {
    let displays = try SimulatorDisplayProtocol.displays(
      displayReply([
        displayValue(id: "cover", active: false, primary: true),
        displayValue(id: "inner", active: true, rotation: "rot90"),
      ]))
    let selected = try SimulatorDisplayCommands.activeIntegratedDisplay(in: displays)
    XCTAssertEqual(selected.uniqueID, "inner")
    XCTAssertEqual(selected.size, CGSize(width: 2853, height: 2007))
    XCTAssertEqual(selected.scale, 3)
  }

  // Measured on the iPhone Duo: the CoreDevice records number the main display 1 and the inner one 3, and
  // an accessibility hit-test names a display by that number.
  func testDisplayIdIsReadWhenReported() throws {
    let displays = try SimulatorDisplayProtocol.displays(
      displayReply([
        displayValue(id: "cover", active: false, primary: true, displayId: 1),
        displayValue(id: "inner", active: true, rotation: "rot90", displayId: 3),
        displayValue(id: "unnumbered", active: false),
      ]))
    XCTAssertEqual(displays.map(\.displayId), [1, 3, nil])
    // Decoded as strictly as every other field.
    let value = displayValue(id: "inner", active: true)
    xpc_dictionary_set_string(value, "displayId", "3")
    XCTAssertThrowsError(try SimulatorDisplayProtocol.displays(displayReply([value])))
  }

  func testActivityCannotBeInferredFromMissingFieldOrStaleReport() {
    let value = displayValue(id: "cover", active: true, primary: true)
    XCTAssertThrowsError(try SimulatorDisplayProtocol.displays(displayReply([value], current: false)))
    xpc_dictionary_set_value(value, "active", nil)
    XCTAssertThrowsError(try SimulatorDisplayProtocol.displays(displayReply([value])))
  }

  func testAmbiguousAndMissingActiveIntegratedDisplaysFail() throws {
    let values = [displayValue(id: "cover", active: true), displayValue(id: "inner", active: true)]
    let displays = try SimulatorDisplayProtocol.displays(displayReply(values))
    XCTAssertThrowsError(try SimulatorDisplayCommands.activeIntegratedDisplay(in: displays))
    XCTAssertThrowsError(try SimulatorDisplayCommands.activeIntegratedDisplay(in: []))
    XCTAssertThrowsError(try SimulatorDisplayProtocol.displays(displayReply([values[0], values[0]])))
  }

  func testRotationAndScaleMustBeRecognized() {
    XCTAssertThrowsError(try SimulatorDisplayProtocol.displays(displayReply([displayValue(id: "inner", active: true, rotation: "unknown")])))
    let value = displayValue(id: "inner", active: true)
    xpc_dictionary_set_int64(value, "pointScale", 0)
    XCTAssertThrowsError(try SimulatorDisplayProtocol.displays(displayReply([value])))
  }

  func testActiveBoundsMustBeNonemptyAndFinite() {
    for width in [0, -1, Double.nan, Double.infinity] {
      let value = displayValue(id: "inner", active: true)
      xpc_dictionary_set_value(
        value, "bounds",
        SimulatorCoreDevice.array([
          SimulatorCoreDevice.array([xpc_double_create(0), xpc_double_create(0)]),
          SimulatorCoreDevice.array([xpc_double_create(width), xpc_double_create(2007)]),
        ]))
      XCTAssertThrowsError(try SimulatorDisplayProtocol.displays(displayReply([value])))
    }
  }

  func testHitTestReachesTheOnlyIntegratedDisplayAsTheMainScreen() throws {
    let single = try SimulatorDisplayProtocol.displays(
      displayReply([
        displayValue(id: "lcd", active: nil, primary: true, displayId: 1, backlight: "off"),
        displayValue(id: "tv", active: nil, displayId: 2, backlight: "off", type: "external"),
      ]))
    XCTAssertEqual(try SimulatorDisplayCommands.hitTestTarget(displayUniqueID: nil, in: single), .mainScreen)
    XCTAssertEqual(try SimulatorDisplayCommands.hitTestTarget(displayUniqueID: "lcd", in: single), .mainScreen)
    let legacy = try SimulatorDisplayProtocol.displays(
      displayReply([
        displayValue(id: nil, active: nil, primary: true, displayId: 1, backlight: "unknown"),
        displayValue(id: nil, active: nil, displayId: 2, backlight: "unknown", type: "external"),
      ]))
    XCTAssertEqual(try SimulatorDisplayCommands.hitTestTarget(displayUniqueID: nil, in: legacy), .mainScreen)
    XCTAssertEqual(try SimulatorDisplayCommands.hitTestTarget(displayUniqueID: "legacy-1", in: legacy), .mainScreen)
  }

  // A hit-test needs no touchscreen, so any lit display can be named, integrated or not.
  func testHitTestNamesAnyLitDisplayOfSeveral() throws {
    let displays = try SimulatorDisplayProtocol.displays(
      displayReply([
        displayValue(id: "cover", active: false, primary: true, displayId: 1),
        displayValue(id: "inner", active: true, rotation: "rot90", displayId: 3),
        displayValue(id: "external", active: true, displayId: 4, type: "external"),
      ]))
    let inner = try XCTUnwrap(displays.first { $0.uniqueID == "inner" })
    let external = try XCTUnwrap(displays.first { $0.uniqueID == "external" })
    XCTAssertEqual(try SimulatorDisplayCommands.hitTestTarget(displayUniqueID: nil, in: displays), .display(inner))
    XCTAssertEqual(try SimulatorDisplayCommands.hitTestTarget(displayUniqueID: "inner", in: displays), .display(inner))
    XCTAssertEqual(try SimulatorDisplayCommands.hitTestTarget(displayUniqueID: "external", in: displays), .display(external))
    XCTAssertThrowsError(try SimulatorDisplayCommands.hitTestTarget(displayUniqueID: "cover", in: displays)) { error in
      guard case .inactiveDisplay("cover")? = error as? SimulatorDisplayError else {
        return XCTFail("Expected inactiveDisplay, got \(error)")
      }
    }
    XCTAssertThrowsError(try SimulatorDisplayCommands.hitTestTarget(displayUniqueID: "missing", in: displays)) { error in
      guard case let .unknownDisplay(id, known)? = error as? SimulatorDisplayError else {
        return XCTFail("Expected unknownDisplay, got \(error)")
      }
      XCTAssertEqual(id, "missing")
      XCTAssertEqual(known, ["cover", "external", "inner"])
    }
  }

  // Measured on the iPhone Duo unfolded (inner display rot90): a hit-test at panel point (300, 700) on
  // display 3 answered the element under interface point (251, 300).
  func testHitTestPointIsTheInterfacePointOnTheUnrotatedPanel() throws {
    let displays = try SimulatorDisplayProtocol.displays(
      displayReply([displayValue(id: "inner", active: true, rotation: "rot90", displayId: 3)]))
    XCTAssertEqual(try displays[0].geometry.unrotatedPoint(from: CGPoint(x: 251, y: 300)), CGPoint(x: 300, y: 700))
  }

  private func readDisplays(from services: SyntheticXPCServices, timeout: DispatchTimeInterval = .seconds(5)) async throws -> [SimulatorDisplay] {
    let channel = try services.channel(to: SimulatorDisplayProtocol.service)
    return try await CoreDeviceSession<[SimulatorDisplay]>(channel: channel, timeout: timeout)
      .read(SimulatorCoreDevice.dictionary([:]), decode: SimulatorDisplayProtocol.displays)
  }

  func testSnapshotCompletesAndClosesTheConnection() async throws {
    let services = SyntheticXPCServices()
    let peer = services.register(
      SimulatorDisplayProtocol.service, respond: SyntheticXPCPeer.replying(displayReply([displayValue(id: "inner", active: true)])))
    let result = try await readDisplays(from: services)
    XCTAssertEqual(result.map(\.uniqueID), ["inner"])
    XCTAssertEqual(peer.received.count, 1)
    let closed = await peer.closed(atLeast: 1)
    XCTAssertEqual(closed, 1)
  }

  func testTimeoutDoesNotProduceEmptySuccess() async {
    let services = SyntheticXPCServices()
    let peer = services.register(SimulatorDisplayProtocol.service, respond: SyntheticXPCPeer.silent)
    do {
      _ = try await readDisplays(from: services, timeout: .milliseconds(500))
      XCTFail("Expected a failed snapshot")
    } catch {
      guard case SimulatorCoreDeviceError.timedOut = error else { return XCTFail("Unexpected error: \(error)") }
    }
    let closed = await peer.closed(atLeast: 1)
    XCTAssertEqual(closed, 1)
  }

  func testPeerLossDoesNotProduceEmptySuccess() async {
    let services = SyntheticXPCServices()
    services.register(SimulatorDisplayProtocol.service) { $0.interrupt() }
    do {
      _ = try await readDisplays(from: services)
      XCTFail("Expected a failed snapshot")
    } catch {
      guard case SimulatorCoreDeviceError.unavailable = error else { return XCTFail("Unexpected error: \(error)") }
    }
  }

  func testProviderErrorIsPropagated() async {
    let services = SyntheticXPCServices()
    let peer = services.register(
      SimulatorDisplayProtocol.service,
      respond: SyntheticXPCPeer.replying(
        SimulatorCoreDevice.dictionary([
          "CoreDevice.error": SimulatorCoreDevice.dictionary([
            "domain": xpc_string_create("provider"), "code": xpc_int64_create(42),
          ])
        ])))
    do {
      _ = try await readDisplays(from: services)
      XCTFail("Expected provider failure")
    } catch { XCTAssertTrue(error.localizedDescription.contains("provider (42)")) }
    let closed = await peer.closed(atLeast: 1)
    XCTAssertEqual(closed, 1)
  }

  func testCancellationClosesOutstandingSnapshot() async {
    let services = SyntheticXPCServices()
    let peer = services.register(SimulatorDisplayProtocol.service, respond: SyntheticXPCPeer.silent)
    let task = Task { try await readDisplays(from: services) }
    _ = await peer.received(atLeast: 1)
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch { XCTAssertTrue(error is CancellationError) }
    let closed = await peer.closed(atLeast: 1)
    XCTAssertEqual(closed, 1)
  }
}
