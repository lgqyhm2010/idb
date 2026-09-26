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

  // Measured on the iPhone Duo unfolded (inner display rot90): a swipe up from the bottom of the
  // interface flagged with the bottom edge did nothing, and flagged with the right edge went home. The
  // edge has to take the same rotation as the point, so the midpoint of each interface edge must land
  // on the panel edge it is flagged with.
  func testEdgesAreCarriedThroughTheRotationTheirPointsAre() {
    let size = CGSize(width: 2007, height: 2853)  // 669x951 points, unrotated
    let rotations: [SimulatorDisplayRotation] = [.upright, .clockwise, .upsideDown, .counterclockwise]
    for rotation in rotations {
      let target = SimulatorTouchTarget(
        displayUniqueID: "inner", digitizerTarget: 2, pixelSize: size, scale: 3, rotation: rotation)
      let sideways = rotation == .clockwise || rotation == .counterclockwise
      let width: CGFloat = sideways ? 951 : 669
      let height: CGFloat = sideways ? 669 : 951
      let midpoints: [(SimulatorHIDEdge, CGPoint)] = [
        (.top, CGPoint(x: width / 2, y: 0)),
        (.left, CGPoint(x: 0, y: height / 2)),
        (.bottom, CGPoint(x: width / 2, y: height)),
        (.right, CGPoint(x: width, y: height / 2)),
      ]
      for (edge, point) in midpoints {
        let ratio = target.digitizerRatio(for: point)
        let panelEdge: SimulatorHIDEdge
        switch (ratio.x, ratio.y) {
        case (_, 0): panelEdge = .top
        case (0, _): panelEdge = .left
        case (_, 1): panelEdge = .bottom
        default: panelEdge = .right
        }
        XCTAssertEqual(target.panelEdge(for: edge), panelEdge, "\(rotation) \(edge)")
      }
      XCTAssertEqual(target.panelEdge(for: .none), SimulatorHIDEdge.none, "\(rotation)")
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

  /// Lists a touchscreen for each attached display, numbered by how many listings have been read.
  private actor Reads {
    var count = 0
    private var attached: [String]

    init(attached: [String]) {
      self.attached = attached
    }

    func attach(_ displayIDs: [String]) {
      attached = displayIDs
    }

    func read() -> [SimulatorTouchscreen] {
      count += 1
      return attached.map { SimulatorTouchscreen(displayUniqueID: $0, digitizerTarget: UInt32(count)) }
    }
  }

  private let size = CGSize(width: 2007, height: 2853)
  private var folded: [SimulatorDisplay] {
    [
      display("cover", active: true, primary: true, size: size),
      display("inner", active: false, primary: false, size: size),
    ]
  }
  private var unfolded: [SimulatorDisplay] {
    [
      display("cover", active: false, primary: true, size: size),
      display("inner", active: true, primary: false, size: size),
    ]
  }

  func testTheListingIsReusedWhileTheDisplaysAreTheSame() async throws {
    let topology = SimulatorTouchscreenTopology()
    let reads = Reads(attached: ["cover", "inner"])
    let first = try await topology.touchTarget(displayUniqueID: nil, displays: unfolded) { await reads.read() }
    let second = try await topology.touchTarget(displayUniqueID: nil, displays: Array(unfolded.reversed())) {
      await reads.read()
    }
    XCTAssertEqual(first, second)
    let count = await reads.count
    XCTAssertEqual(count, 1)
  }

  func testTheListingIsReadAgainWhenTheDisplaysChange() async throws {
    let topology = SimulatorTouchscreenTopology()
    let reads = Reads(attached: ["cover", "inner"])
    _ = try await topology.touchTarget(displayUniqueID: nil, displays: unfolded) { await reads.read() }
    let external = display("external", active: false, primary: false, size: size)
    let after = try await topology.touchTarget(displayUniqueID: nil, displays: unfolded + [external]) {
      await reads.read()
    }
    XCTAssertEqual(after.digitizerTarget, 2)
    let count = await reads.count
    XCTAssertEqual(count, 2)
  }

  // A foldable can attach a display's touchscreen only once that display lights up, so the listing
  // read while it was dark is not reused for it.
  func testTheListingIsReadAgainWhenADisplayLightsUp() async throws {
    let topology = SimulatorTouchscreenTopology()
    let reads = Reads(attached: ["cover"])
    let closed = try await topology.touchTarget(displayUniqueID: nil, displays: folded) { await reads.read() }
    XCTAssertEqual(closed.displayUniqueID, "cover")

    await reads.attach(["cover", "inner"])
    let open = try await topology.touchTarget(displayUniqueID: nil, displays: unfolded) { await reads.read() }
    XCTAssertEqual(open.displayUniqueID, "inner")
    XCTAssertEqual(open.digitizerTarget, 2)
    let count = await reads.count
    XCTAssertEqual(count, 2)
  }

  // A kept listing can be stale although the displays look the same, so a display it has no
  // touchscreen for is looked up once more in a fresh listing; a fresh listing is believed.
  func testAMissInAKeptListingIsReadOnceMoreBeforeItIsReported() async throws {
    let topology = SimulatorTouchscreenTopology()
    let reads = Reads(attached: [])

    // Fresh listing: the miss is reported without another read.
    var missed = try await innerHasNoTouchscreen(topology, reads)
    XCTAssertTrue(missed)
    var count = await reads.count
    XCTAssertEqual(count, 1)

    // Kept listing: read once more, and the miss stands when the fresh one agrees.
    missed = try await innerHasNoTouchscreen(topology, reads)
    XCTAssertTrue(missed)
    count = await reads.count
    XCTAssertEqual(count, 2)

    // Kept listing: the fresh one finds the touchscreen that attached since.
    await reads.attach(["inner"])
    let target = try await topology.touchTarget(displayUniqueID: "inner", displays: unfolded) { await reads.read() }
    XCTAssertEqual(target.digitizerTarget, 3)
    count = await reads.count
    XCTAssertEqual(count, 3)

    // The fresh listing is the one kept afterwards.
    _ = try await topology.touchTarget(displayUniqueID: "inner", displays: unfolded) { await reads.read() }
    count = await reads.count
    XCTAssertEqual(count, 3)
  }

  func testConcurrentResolutionsShareOneRead() async throws {
    let topology = SimulatorTouchscreenTopology()
    let reads = Reads(attached: ["inner"])
    let displays = unfolded
    async let first = topology.touchTarget(displayUniqueID: "inner", displays: displays) {
      try await Task.sleep(for: .milliseconds(50))
      return await reads.read()
    }
    async let second = topology.touchTarget(displayUniqueID: "inner", displays: displays) {
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
    let reads = Reads(attached: ["inner"])
    do {
      _ = try await topology.touchTarget(displayUniqueID: "inner", displays: unfolded) {
        throw SimulatorDisplayError.changed
      }
      XCTFail("The failing read should throw")
    } catch {}
    _ = try await topology.touchTarget(displayUniqueID: "inner", displays: unfolded) { await reads.read() }
    let count = await reads.count
    XCTAssertEqual(count, 1)
  }

  /// Whether resolving the inner display reports that it has no touchscreen.
  private func innerHasNoTouchscreen(_ topology: SimulatorTouchscreenTopology, _ reads: Reads) async throws -> Bool {
    do {
      _ = try await topology.touchTarget(displayUniqueID: "inner", displays: unfolded) { await reads.read() }
      return false
    } catch SimulatorDisplayError.noTouchscreen("inner") {
      return true
    }
  }
}

private func display(_ id: String, active: Bool, primary: Bool, size: CGSize) -> SimulatorDisplay {
  SimulatorDisplay(
    uniqueID: id, name: id, isActive: active, isPrimary: primary, isIntegrated: true,
    bounds: CGRect(origin: .zero, size: size), scale: 3, rotation: .upsideDown)
}
