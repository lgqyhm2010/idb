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
/// The report UUID maps to accessibility identity 42, independently of any report numeric ID.
final class AccessibilityPointOnDisplayTests: XCTestCase {

  private static let query = AccessibilityElementQuery.pointOnDisplay(
    CGPoint(x: 251, y: 300), uniqueID: "inner")

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
  private func setUpSimulator(displays suppliedDisplays: DisplayCommandsDouble? = nil) throws {
    let fixture = AccessibilityTestFixture.bootedSimulator()
    fixture.rootElement = AccessibilityTestElementBuilder.button(
      withLabel: "OK", identifier: "ok_button", frame: NSRect(x: 200, y: 250, width: 100, height: 100))
    try fixture.setUp()
    self.fixture = fixture

    let sim = SimulatorTestSupport.testableSimulator(withDevice: fixture.device)
    let dispatcher = Simulator.createAccessibilityTranslationDispatcher(withTranslator: fixture.translator)
    let display = SimulatorDisplay(
      uniqueID: "inner", name: "Inner", activity: .active, isPrimary: false, isIntegrated: true,
      bounds: CGRect(x: 0, y: 0, width: 2007, height: 2853), scale: 3, rotation: .clockwise)
    let displays = suppliedDisplays ?? DisplayCommandsDouble(.selected(display))
    displays.identities.remember([SimulatorAccessibilityDisplay(uniqueID: "inner", displayID: 42)])
    let commands = SimulatorAccessibilityCommands(simulator: sim, translationDispatcher: dispatcher, displays: displays)
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
  // the panel point on display inner. Asking at the caller's point, or on the main-screen alias, answers for
  // somewhere else.
  func testTheTranslatorIsAskedAtThePanelPointOnTheNamedDisplay() async throws {
    try setUpSimulator()
    let element = try await simulator.accessibility.resolveElement(for: Self.query)
    element.close()
    XCTAssertEqual(hitTests, ["objectAtPoint:{300.0,700.0} displayId:42"])
  }

  func testAPlainPointStillUsesUpstreamActiveDisplayRouting() async throws {
    try setUpSimulator()
    let element = try await simulator.accessibility.resolveElement(for: .point(CGPoint(x: 251, y: 300)))
    element.close()
    XCTAssertEqual(hitTests, ["objectAtPoint:{300.0,700.0} displayId:42"])
  }

  // `--format complete` echoes the target back, and the caller named the point in the display's interface
  // orientation — the same space as the frames the read reports. The panel point is a conversion made on
  // their behalf and never theirs to recognise.
  func testTheReadReportsTheCallersPointAsItsTarget() async throws {
    XCTAssertEqual(Self.query.targetDescriptor, .point(CGPoint(x: 251, y: 300)))
    XCTAssertEqual(Self.query.description, "the element at (251.0, 300.0) on display inner")

    try setUpSimulator()
    let response = try await simulator.uiAutomation(backend: .accessibility)
      .describe(Self.query, options: AccessibilityRequestOptions())
    XCTAssertEqual(response.target, AccessibilityTargetDescriptor.point(CGPoint(x: 251, y: 300)))
    XCTAssertEqual(hitTests, ["objectAtPoint:{300.0,700.0} displayId:42"])
  }

  func testAXSoleReadRejectsAChangedUUIDAfterSerialization() async throws {
    try await assertAXReadRejectsDisplayChange(
      from: .sole(.identified(axDisplay())), to: .sole(.identified(axDisplay(id: "cover"))))
  }

  func testAXSoleReadRejectsRotationAfterSerialization() async throws {
    try await assertAXReadRejectsDisplayChange(
      from: .sole(.identified(axDisplay())), to: .sole(.identified(axDisplay(rotation: .upright))))
  }

  func testAXCachedSelectedReadRejectsRotationAfterSerialization() async throws {
    try await assertAXReadRejectsDisplayChange(
      from: .selected(axDisplay()), to: .selected(axDisplay(rotation: .upright)))
  }

  func testAXCachedSelectedReadRejectsASwitchToTheSoleAliasAfterSerialization() async throws {
    try await assertAXReadRejectsDisplayChange(
      from: .selected(axDisplay()), to: .sole(.identified(axDisplay())))
  }

  func testAXSelectedReadRejectsAnObservedIdentityChangeBeforeSerializationCompletes() async throws {
    let displays = DisplayCommandsDouble(.selected(axDisplay()))
    try setUpSimulator(displays: displays)
    let element = try await simulator.accessibility.resolveElement(for: Self.query)
    defer { element.close() }
    displays.identities.remember([SimulatorAccessibilityDisplay(uniqueID: "inner", displayID: 71)])
    do {
      _ = try await element.serialize(with: AccessibilityRequestOptions())
      XCTFail("A refreshed mapping must invalidate the earlier hit-test")
    } catch SimulatorDisplayError.changed {}
    XCTAssertEqual(displays.reads, 2)
    XCTAssertTrue(fixture?.rootElement?.accessedProperties.contains("accessibilityLabel") == true)
  }

  private func axDisplay(id: String = "inner", rotation: SimulatorDisplayRotation = .clockwise) -> SimulatorDisplay {
    SimulatorDisplay(
      uniqueID: id, name: id, activity: .active, isPrimary: true, isIntegrated: true,
      bounds: CGRect(x: 0, y: 0, width: 2007, height: 2853), scale: 3, rotation: rotation)
  }

  private func assertAXReadRejectsDisplayChange(
    from initial: SimulatorDisplayTarget, to changed: SimulatorDisplayTarget,
    file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    // The first read resolves the query. The next report is only consumed by post-serialization
    // validation: cached selected identities and the sole alias both avoid inventory round trips.
    let displays = DisplayCommandsDouble(initial, changed)
    try setUpSimulator(displays: displays)
    XCTAssertEqual(displays.identities.accessibilityID(for: "inner"), 42)
    do {
      _ = try await simulator.uiAutomation(backend: .accessibility)
        .describe(Self.query, options: AccessibilityRequestOptions())
      XCTFail("A display change must not return the earlier snapshot's result", file: file, line: line)
    } catch SimulatorDisplayError.changed {}
    XCTAssertEqual(displays.reads, 2, file: file, line: line)
    XCTAssertEqual(hitTests.count, 1, file: file, line: line)
    XCTAssertTrue(
      fixture?.rootElement?.accessedProperties.contains("accessibilityLabel") == true,
      "Validation runs after attribute serialization, not merely after the initial hit-test", file: file, line: line)
  }

  func testImplicitAXPointKeepsUpstreamReadBehavior() async throws {
    let displays = DisplayCommandsDouble(.sole(.identified(axDisplay())), .sole(.identified(axDisplay(id: "cover"))))
    try setUpSimulator(displays: displays)
    _ = try await simulator.uiAutomation(backend: .accessibility)
      .describe(.point(CGPoint(x: 251, y: 300)), options: AccessibilityRequestOptions())
    XCTAssertEqual(displays.reads, 1, "Post-serialization validation is restricted to explicit UUID queries")
  }

  func testAnExternalDisplayUsesItsAccessibilityIdentityWithoutATouchscreen() async throws {
    let display = SimulatorDisplay(
      uniqueID: "external", name: "External", activity: .active, isPrimary: false, isIntegrated: false,
      bounds: CGRect(x: 0, y: 0, width: 1200, height: 800), scale: 2, rotation: .upright)
    let displays = DisplayCommandsDouble([.success(.displays([display]))])
    let resolved = try await displays.resolveDisplay(uniqueID: "external")
    XCTAssertEqual(resolved, .target(.selected(display)))
    let transport = InventoryTransport([SimulatorAccessibilityDisplay(uniqueID: "external", displayID: 71)])
    let identity = try await displays.accessibilityID(
      for: display, transport: transport, validatesActiveDisplay: false)
    XCTAssertEqual(identity, 71)
    XCTAssertEqual(displays.touchscreenReads, 0)
    let sends = await transport.sends
    XCTAssertEqual(sends, 1)
  }

  func testUnknownAndInactiveDisplaysCannotFallBackToTheActiveDisplay() async throws {
    let display = SimulatorDisplay(
      uniqueID: "inner", name: "Inner", activity: .active, isPrimary: false, isIntegrated: true,
      bounds: CGRect(x: 0, y: 0, width: 1200, height: 800), scale: 2, rotation: .upright)
    let displays = DisplayCommandsDouble(.selected(display))
    do {
      _ = try await displays.resolveDisplay(uniqueID: "missing")
      XCTFail("Unknown display must not read the active display")
    } catch let SimulatorDisplayError.unknownDisplay(id, known) {
      XCTAssertEqual(id, "missing")
      XCTAssertTrue(known.contains("inner"))
    }
    do {
      _ = try await displays.resolveDisplay(uniqueID: "inner-inactive")
      XCTFail("A dark display cannot be hit-tested")
    } catch let SimulatorDisplayInteractionError.inactiveDisplay(id) {
      XCTAssertEqual(id, "inner-inactive")
    }
  }

  func testIdentityDiscoveryRejectsANamedDisplayThatChangesGeometry() async throws {
    let display = SimulatorDisplay(
      uniqueID: "external", name: "External", activity: .active, isPrimary: false, isIntegrated: false,
      bounds: CGRect(x: 0, y: 0, width: 1200, height: 800), scale: 2, rotation: .upright)
    let changed = SimulatorDisplay(
      uniqueID: "external", name: "External", activity: .active, isPrimary: false, isIntegrated: false,
      bounds: CGRect(x: 0, y: 0, width: 800, height: 1200), scale: 2, rotation: .clockwise)
    let displays = DisplayCommandsDouble([.success(.displays([changed]))])
    let transport = InventoryTransport([SimulatorAccessibilityDisplay(uniqueID: "external", displayID: 71)])
    do {
      _ = try await displays.accessibilityID(for: display, transport: transport, validatesActiveDisplay: false)
      XCTFail("A mapping acquired across a configuration change must not be used")
    } catch SimulatorDisplayError.changed {}
    XCTAssertNil(displays.identities.accessibilityID(for: "external"))
  }

  func testBridgeExplicitSoleReadRetainsItsDisplayAndRejectsChanges() async throws {
    let display = SimulatorDisplay(
      uniqueID: "sole", name: "Sole", activity: .active, isPrimary: true, isIntegrated: true,
      bounds: CGRect(x: 0, y: 0, width: 1200, height: 800), scale: 2, rotation: .upright)
    let changed = SimulatorDisplay(
      uniqueID: "sole", name: "Sole", activity: .active, isPrimary: true, isIntegrated: true,
      bounds: CGRect(x: 0, y: 0, width: 800, height: 1200), scale: 2, rotation: .clockwise)
    for changes in [false, true] {
      let displays = DisplayCommandsDouble([
        .success(.displays([display])), .success(.displays([changes ? changed : display]))])
      let transport = PointOnDisplayBridgeTransport(answerHitTests: true)
      let automation = AXBridgeUIAutomation(
        simulator: SimulatorTestSupport.testableSimulator(withDevice: PointOnDisplayBridgeDevice()),
        transport: transport, persistence: .exclusive, displays: displays)
      do {
        let response = try await automation.describe(
          .pointOnDisplay(CGPoint(x: 20, y: 30), uniqueID: "sole"), options: AccessibilityRequestOptions())
        XCTAssertFalse(changes, "A changed configuration must not return a hit from another snapshot")
        XCTAssertEqual(response.screen?.display?.uniqueID, "sole")
      } catch SimulatorDisplayError.changed {
        XCTAssertTrue(changes)
      }
      let requests = await transport.requests
      XCTAssertEqual(requests.count, 1)
    }
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

  // Explicit non-sole display queries remain read-only AX queries. The bridge refuses them
  // rather than silently resolving its usual active integrated display.
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
  private let answerHitTests: Bool

  init(answerHitTests: Bool = false) { self.answerHitTests = answerHitTests }

  func send(_ request: AXBridgeRequest) async throws -> Data {
    requests.append(request)
    if answerHitTests { return Data(#"{"ok":true,"tree":{},"pid":123}"#.utf8) }
    throw AXBridgeError.bridgeUnavailable
  }
}
