/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
@testable import FBSimulatorControl
import XCTest

final class SimulatorTouchTargetTests: XCTestCase {

  // An unfolded iPhone Duo: the cover is the main display and dark, the inner display is lit.
  private let cover = display("cover", active: false, primary: true, size: CGSize(width: 1398, height: 2034))
  private let inner = display("inner", active: true, primary: false, size: CGSize(width: 2007, height: 2853))
  private let touchscreens = [
    SimulatorTouchscreen(displayUniqueID: "cover", digitizerTarget: 1),
    SimulatorTouchscreen(displayUniqueID: "inner", digitizerTarget: 2),
  ]

  func testNamedDisplayResolvesToItsTouchscreenAndGeometry() throws {
    let target = try SimulatorTouchTarget.resolve(
      displayUniqueID: "inner", displays: [cover, inner], touchscreens: touchscreens)
    XCTAssertEqual(
      target,
      SimulatorTouchTarget(
        displayUniqueID: "inner", digitizerTarget: 2, pixelSize: CGSize(width: 2007, height: 2853), scale: 3,
        rotation: .upsideDown))
  }

  // Measured on the iPhone Duo: its inner display reports rot180 in portrait, and a touch aimed at the
  // dock at the bottom of its screenshot lands at the top unless it is carried back through that.
  func testPointsAreCarriedBackThroughTheDisplayRotation() {
    let size = CGSize(width: 2007, height: 2853)  // 669x951 points, unrotated
    let cases: [(SimulatorDisplayRotation, CGPoint, CGPoint)] = [
      (.upright, CGPoint(x: 66.9, y: 95.1), CGPoint(x: 0.1, y: 0.1)),
      (.upsideDown, CGPoint(x: 66.9, y: 95.1), CGPoint(x: 0.9, y: 0.9)),
      // Landscape: the interface is 951 wide and 669 tall.
      (.clockwise, CGPoint(x: 95.1, y: 66.9), CGPoint(x: 0.1, y: 0.9)),
      (.counterclockwise, CGPoint(x: 95.1, y: 66.9), CGPoint(x: 0.9, y: 0.1)),
    ]
    for (rotation, point, expected) in cases {
      let target = SimulatorTouchTarget(
        displayUniqueID: "inner", digitizerTarget: 2, pixelSize: size, scale: 3, rotation: rotation)
      let ratio = target.digitizerRatio(for: point)
      XCTAssertEqual(ratio.x, expected.x, accuracy: 1e-9, "\(rotation)")
      XCTAssertEqual(ratio.y, expected.y, accuracy: 1e-9, "\(rotation)")
    }
  }

  func testNoDisplaySelectsTheActiveIntegratedOne() throws {
    let target = try SimulatorTouchTarget.resolve(displayUniqueID: nil, displays: [cover, inner], touchscreens: touchscreens)
    XCTAssertEqual(target.displayUniqueID, "inner")
    XCTAssertEqual(target.digitizerTarget, 2)
  }

  // Every failed join is an error, never the main screen: a misrouted touch reports success.
  func testUnknownDisplayIsRejectedNamingTheKnownOnes() {
    XCTAssertThrowsError(
      try SimulatorTouchTarget.resolve(displayUniqueID: "missing", displays: [cover, inner], touchscreens: touchscreens)
    ) { error in
      guard case let .unknownDisplay(id, known)? = error as? SimulatorDisplayError else {
        return XCTFail("Expected unknownDisplay, got \(error)")
      }
      XCTAssertEqual(id, "missing")
      XCTAssertEqual(known, ["cover", "inner"])
    }
  }

  func testInactiveDisplayIsRejected() {
    XCTAssertThrowsError(
      try SimulatorTouchTarget.resolve(displayUniqueID: "cover", displays: [cover, inner], touchscreens: touchscreens)
    ) { error in
      guard case .inactiveDisplay("cover")? = error as? SimulatorDisplayError else {
        return XCTFail("Expected inactiveDisplay, got \(error)")
      }
    }
  }

  func testDisplayWithoutATouchscreenIsRejected() {
    XCTAssertThrowsError(
      try SimulatorTouchTarget.resolve(displayUniqueID: "inner", displays: [cover, inner], touchscreens: [touchscreens[0]])
    ) { error in
      guard case .noTouchscreen("inner")? = error as? SimulatorDisplayError else {
        return XCTFail("Expected noTouchscreen, got \(error)")
      }
    }
  }

  func testNoActiveDisplayIsRejected() {
    XCTAssertThrowsError(
      try SimulatorTouchTarget.resolve(displayUniqueID: nil, displays: [cover], touchscreens: touchscreens)
    ) { error in
      guard case .noActiveIntegratedDisplay? = error as? SimulatorDisplayError else {
        return XCTFail("Expected noActiveIntegratedDisplay, got \(error)")
      }
    }
  }
}

final class SimulatorTouchscreenTopologyTests: XCTestCase {

  private actor Reads {
    var count = 0
    func read() -> [SimulatorTouchscreen] {
      count += 1
      return [SimulatorTouchscreen(displayUniqueID: "inner", digitizerTarget: UInt32(count))]
    }
  }

  func testTheListingIsReusedWhileTheDisplaysAreTheSame() async throws {
    let topology = SimulatorTouchscreenTopology()
    let reads = Reads()
    let first = try await topology.touchscreens(forDisplays: ["cover", "inner"]) { await reads.read() }
    let second = try await topology.touchscreens(forDisplays: ["inner", "cover"]) { await reads.read() }
    XCTAssertEqual(first, second)
    let count = await reads.count
    XCTAssertEqual(count, 1)
  }

  func testTheListingIsReadAgainWhenTheDisplaysChange() async throws {
    let topology = SimulatorTouchscreenTopology()
    let reads = Reads()
    _ = try await topology.touchscreens(forDisplays: ["cover", "inner"]) { await reads.read() }
    let after = try await topology.touchscreens(forDisplays: ["cover", "inner", "external"]) { await reads.read() }
    XCTAssertEqual(after.first?.digitizerTarget, 2)
    let count = await reads.count
    XCTAssertEqual(count, 2)
  }

  func testConcurrentResolutionsShareOneRead() async throws {
    let topology = SimulatorTouchscreenTopology()
    let reads = Reads()
    async let first = topology.touchscreens(forDisplays: ["inner"]) {
      try await Task.sleep(for: .milliseconds(50))
      return await reads.read()
    }
    async let second = topology.touchscreens(forDisplays: ["inner"]) {
      try await Task.sleep(for: .milliseconds(50))
      return await reads.read()
    }
    let (a, b) = try await (first, second)
    XCTAssertEqual(a, b)
    let count = await reads.count
    XCTAssertEqual(count, 1)
  }

  func testAFailedReadIsNotRemembered() async throws {
    let topology = SimulatorTouchscreenTopology()
    let reads = Reads()
    do {
      _ = try await topology.touchscreens(forDisplays: ["inner"]) { throw SimulatorDisplayError.changed }
      XCTFail("The failing read should throw")
    } catch {}
    _ = try await topology.touchscreens(forDisplays: ["inner"]) { await reads.read() }
    let count = await reads.count
    XCTAssertEqual(count, 1)
  }
}

private func display(_ id: String, active: Bool, primary: Bool, size: CGSize) -> SimulatorDisplay {
  SimulatorDisplay(
    uniqueID: id, name: id, isActive: active, isPrimary: primary, isIntegrated: true,
    bounds: CGRect(origin: .zero, size: size), scale: 3, rotation: .upsideDown)
}
