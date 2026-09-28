/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import FBControlCore
@testable import FBSimulatorControl
import Foundation
import XCTest

/// Coverage for a point read aimed at a display other than the main one, as `describe-point --display`
/// sends it: what the translator is asked, what the read reports as its target, and which verbs refuse it.
///
/// The numbers are the iPhone Duo's, measured unfolded: the inner display is CoreDevice display 3, rotated
/// rot90, and a hit-test at panel (300, 700) on it answered the element under interface point (251, 300).
final class AccessibilityPointOnDisplayTests: XCTestCase {

  private static let query = AccessibilityElementQuery.pointOnDisplay(
    CGPoint(x: 251, y: 300), panelPoint: CGPoint(x: 300, y: 700), displayId: 3)

  private var fixture: AccessibilityTestFixture?
  private var simulator: Simulator!

  override func tearDown() {
    simulator = nil
    fixture?.tearDown()
    fixture = nil
    super.tearDown()
  }

  /// Builds a booted simulator whose accessibility commands run against the translator double, which
  /// answers every hit-test with one button.
  private func setUpSimulator() throws {
    let fixture = AccessibilityTestFixture.bootedSimulator()
    fixture.rootElement = AccessibilityTestElementBuilder.button(
      withLabel: "OK", identifier: "ok_button", frame: NSRect(x: 200, y: 250, width: 100, height: 100))
    try fixture.setUp()
    self.fixture = fixture

    let sim = SimulatorTestSupport.testableSimulator(withDevice: fixture.device)
    let dispatcher = Simulator.createAccessibilityTranslationDispatcher(withTranslator: fixture.translator)
    let commands = SimulatorAccessibilityCommands(simulator: sim, translationDispatcher: dispatcher)
    sim.commandCache.register(commands, as: SimulatorAccessibilityCommands.self)
    simulator = sim
  }

  /// The hit-tests the translator was asked for, without the per-request token.
  private var hitTests: [String] {
    ((fixture?.translator.methodCalls as? [String]) ?? [])
      .filter { $0.hasPrefix("objectAtPoint:") }
      .map { $0.components(separatedBy: " token:")[0] }
  }

  // MARK: - The read

  // The translator hit-tests another display in that display's unrotated panel points, so it is asked at
  // the panel point on display 3. Asking at the caller's point, or on the main-screen alias, answers for
  // somewhere else.
  func testTheTranslatorIsAskedAtThePanelPointOnTheNamedDisplay() async throws {
    try setUpSimulator()
    let element = try await simulator.accessibility.resolveElement(for: Self.query)
    element.close()
    XCTAssertEqual(hitTests, ["objectAtPoint:{300.0,700.0} displayId:3"])
  }

  func testAPlainPointIsAskedOnTheMainScreenAlias() async throws {
    try setUpSimulator()
    let element = try await simulator.accessibility.resolveElement(for: .point(CGPoint(x: 251, y: 300)))
    element.close()
    XCTAssertEqual(hitTests, ["objectAtPoint:{251.0,300.0} displayId:0"])
  }

  // `--format complete` echoes the target back, and the caller named the point in the display's interface
  // orientation — the same space as the frames the read reports. The panel point is a conversion made on
  // their behalf and never theirs to recognise.
  func testTheReadReportsTheCallersPointAsItsTarget() async throws {
    XCTAssertEqual(Self.query.targetDescriptor, .point(CGPoint(x: 251, y: 300)))
    XCTAssertEqual(Self.query.description, "the element at (251.0, 300.0) on display 3")

    try setUpSimulator()
    let response = try await simulator.uiAutomation(backend: .accessibility)
      .describe(Self.query, options: AccessibilityRequestOptions())
    XCTAssertEqual(response.target, AccessibilityTargetDescriptor.point(CGPoint(x: 251, y: 300)))
    XCTAssertEqual(hitTests, ["objectAtPoint:{300.0,700.0} displayId:3"])
  }

  // MARK: - Every other verb

  // The translator would resolve the element on the other display and let the verb act on it, so each verb
  // refuses the query itself, before the translator is asked anything.
  func testTheAccessibilityBackendRefusesEveryVerbButDescribe() async throws {
    try setUpSimulator()
    let automation = try simulator.uiAutomation(backend: .accessibility)
    await assertRefused("A tap on another display", backend: .accessibility) {
      try await automation.tap(Self.query)
    }
    await assertRefused("Setting a value on another display", backend: .accessibility) {
      try await automation.setValue("value", for: Self.query)
    }
    await assertRefused("Scroll on another display", backend: .accessibility) {
      try await automation.scroll(Self.query, direction: .down)
    }
    await assertRefused("Reading a frame on another display", backend: .accessibility) {
      _ = try await automation.frame(Self.query)
    }
    await assertRefused("A drag endpoint on another display", backend: .accessibility) {
      try await automation.drag(from: Self.query, to: .point(.zero))
    }
    XCTAssertEqual(hitTests, [], "a refused verb must not reach the translator")
  }

  // The guest can scope a hit-test to a display, but this host sends it no display id, so the bridge
  // refuses the query rather than answering for the main screen — and before any round trip.
  func testTheBridgeBackendRefusesItWithoutAskingTheGuest() async throws {
    let transport = PointOnDisplayBridgeTransport()
    let automation = AXBridgeUIAutomation(
      simulator: SimulatorTestSupport.testableSimulator(withDevice: PointOnDisplayBridgeDevice()),
      transport: transport,
      persistence: .exclusive)
    let backend = automation.backend
    await assertRefused("Describing a point on another display", backend: backend) {
      _ = try await automation.describe(Self.query, options: AccessibilityRequestOptions())
    }
    await assertRefused("A tap on another display", backend: backend) {
      try await automation.tap(Self.query)
    }
    await assertRefused("Setting a value on another display", backend: backend) {
      try await automation.setValue("value", for: Self.query)
    }
    await assertRefused("Scroll on another display", backend: backend) {
      try await automation.scroll(Self.query, direction: .down)
    }
    await assertRefused("A drag endpoint on another display", backend: backend) {
      try await automation.drag(from: Self.query, to: .point(.zero))
    }
    let requests = await transport.requests
    XCTAssertTrue(requests.isEmpty, "a refused verb must not reach the guest")
  }

  private func assertRefused(
    _ operation: String,
    backend: UIAutomationBackend,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ verb: () async throws -> Void
  ) async {
    do {
      try await verb()
      XCTFail("\(operation) must be refused", file: file, line: line)
    } catch let UIAutomationError.operationUnsupported(thrownBackend, thrownOperation) {
      XCTAssertEqual(thrownBackend, backend, "the refusal must name the backend that refused", file: file, line: line)
      XCTAssertEqual(thrownOperation, operation, file: file, line: line)
    } catch {
      XCTFail("expected operationUnsupported for \(operation), got \(error)", file: file, line: line)
    }
  }
}

@objc private final class PointOnDisplayBridgeDevice: NSObject {
  @objc let UDID = NSUUID()
  @objc var deviceType: NSObject? { nil }
}

/// Records every request and answers none: a verb that refuses its query must never send one.
private actor PointOnDisplayBridgeTransport: AXBridgeTransport {
  private(set) var requests: [AXBridgeRequest] = []

  func send(_ request: AXBridgeRequest) async throws -> Data {
    requests.append(request)
    throw AXBridgeError.bridgeUnavailable
  }
}
