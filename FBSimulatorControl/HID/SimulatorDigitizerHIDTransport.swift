/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
@preconcurrency import CoreSimulator
@preconcurrency import FBControlCore
import Foundation

/// Tracks the per-contact phase so that a stream of Indigo `.down`/`.up` events maps onto the
/// `dtuhidd` `start` / `position` / `end` model: the first `.down` is a `start`, subsequent `.down`s
/// (a drag/swipe) are `position`s, and `.up` is the `end`.
struct DigitizerContactTracker {
  private var active = false

  mutating func eventType(for direction: SimulatorHIDDirection) -> DigitizerEventType {
    switch direction {
    case .down:
      if active {
        return .position
      }
      active = true
      return .start
    case .up:
      active = false
      return .end
    }
  }
}

/// One contact tracker per digitizer target, so contacts on different displays keep their own phases:
/// a shared tracker would turn one display's `start` into a `position` while another's contact is down.
struct DigitizerContacts {
  private var trackers: [UInt64: DigitizerContactTracker] = [:]

  mutating func eventType(for direction: SimulatorHIDDirection, target: UInt64) -> DigitizerEventType {
    trackers[target, default: DigitizerContactTracker()].eventType(for: direction)
  }
}

/**
 The DTUHID digitizer transport (Xcode 27 / macOS 26 / iOS 26+).

 Drives the modern `dtuhidd` daemon's digitizer service: touches, buttons and keys cross the
 host→guest boundary as plain-XPC dictionaries, each built as an `Encodable` model (e.g.
 `IndigoDigitizerEvent`) wrapped in a `DTUHIDMessage` envelope and serialized with `XPCEncoder`.

 A touch goes to digitizer target zero, the main-screen alias, unless a `SimulatorTouchTarget` aims it
 at one display's touchscreen. Only this transport can address one, so the targeted sends are reached
 through `SimulatorHIDTransport` rather than `SimulatorHIDPrimitives`.

 The connection, its liveness probe and its drain are `SimulatorDTUHIDConnection`'s; this type is the
 digitizer encoding over it, and an actor so the contact state it tracks is isolated.
 */
actor SimulatorDigitizerHIDTransport {

  static let serviceName = "com.apple.coredevice.feature.remote.hid.digitizer"

  private let connection: SimulatorDTUHIDConnection
  private let mainScreenSize: CGSize
  private let mainScreenScale: Float
  private let productFamily: ProductFamily
  private var contacts = DigitizerContacts()
  private var twoFingerContacts = DigitizerContacts()

  // MARK: - Initializers

  /// Connects to the simulator's DTUHID digitizer service. See `SimulatorDTUHIDConnection.connect`.
  static func connect(to simulator: Simulator) async throws -> SimulatorDigitizerHIDTransport {
    SimulatorDigitizerHIDTransport(
      connection: try await SimulatorDTUHIDConnection.connect(using: simulator.xpc, serviceName: serviceName),
      mainScreenSize: simulator.device.deviceType.mainScreenSize,
      mainScreenScale: simulator.device.deviceType.mainScreenScale,
      productFamily: simulator.productFamily)
  }

  init(
    connection: SimulatorDTUHIDConnection,
    mainScreenSize: CGSize,
    mainScreenScale: Float,
    productFamily: ProductFamily
  ) {
    self.connection = connection
    self.mainScreenSize = mainScreenSize
    self.mainScreenScale = mainScreenScale
    self.productFamily = productFamily
  }

  // MARK: - Sends

  nonisolated func disconnect() {
    connection.disconnect()
  }

  func flush() async throws {
    try await connection.flush()
  }

  func sendTouch(
    direction: SimulatorHIDDirection, x: Double, y: Double, edge: SimulatorHIDEdge
  ) async throws {
    try await sendTouch(direction: direction, x: x, y: y, edge: edge, target: nil)
  }

  func sendTwoFingerTouch(direction: SimulatorHIDDirection, finger1: CGPoint, finger2: CGPoint) async throws {
    try await sendTwoFingerTouch(direction: direction, finger1: finger1, finger2: finger2, target: nil)
  }

  /// `target` nil sends to digitizer target zero, the main-screen alias, normalized against the main
  /// screen; otherwise to that touchscreen, normalized against its own display.
  func sendTouch(
    direction: SimulatorHIDDirection, x: Double, y: Double, edge: SimulatorHIDEdge, target: SimulatorTouchTarget?
  ) async throws {
    guard productFamily.hasTouchscreen else {
      throw SimulatorHIDError.touchUnsupportedOnAppleTV
    }
    let event = digitizerEvent(
      CGPoint(x: x, y: y), eventType: contacts.eventType(for: direction, target: Self.digitizerTarget(target)),
      edge: edge, target: target)
    try await send(messageType: "IndigoDigitizerEvent", payload: event)
  }

  func sendTwoFingerTouch(
    direction: SimulatorHIDDirection, finger1: CGPoint, finger2: CGPoint, target: SimulatorTouchTarget?
  ) async throws {
    guard productFamily.hasTouchscreen else {
      throw SimulatorHIDError.touchUnsupportedOnAppleTV
    }
    let event = digitizerEvent(
      finger1, finger2, eventType: twoFingerContacts.eventType(for: direction, target: Self.digitizerTarget(target)),
      target: target)
    try await send(messageType: "IndigoDigitizerEvent", payload: event)
  }

  /// The digitizer target a touch is addressed to: `target`'s touchscreen, or zero, the main-screen alias.
  static func digitizerTarget(_ target: SimulatorTouchTarget?) -> UInt64 {
    // Widening: the touchscreen listing carries the low byte of a 0x100-namespace service ID.
    target.map { UInt64($0.digitizerTarget) } ?? 0
  }

  /// The digitizer event for one or two contacts given in points, addressed to `target`'s touchscreen
  /// and normalized against its display, or to the main screen when `target` is nil. The edge is
  /// given in the same interface orientation as the points and carried through the same rotation.
  nonisolated func digitizerEvent(
    _ first: CGPoint, _ second: CGPoint? = nil, eventType: DigitizerEventType, edge: SimulatorHIDEdge = .none,
    target: SimulatorTouchTarget?
  ) -> IndigoDigitizerEvent {
    func normalized(_ point: CGPoint) -> DigitizerPoint {
      let ratio =
        target?.digitizerRatio(for: point)
        ?? SimulatorIndigoHID.screenRatio(from: point, screenSize: mainScreenSize, screenScale: mainScreenScale)
      return DigitizerPoint(x: Double(ratio.x), y: Double(ratio.y))
    }
    return IndigoDigitizerEvent(
      pointOne: normalized(first),
      pointTwo: second.map(normalized),
      eventType: eventType,
      edge: UInt64((target?.digitizerEdge(for: edge) ?? edge).rawValue),
      target: Self.digitizerTarget(target))
  }

  func sendButton(direction: SimulatorHIDDirection, button: SimulatorHIDButton) async throws {
    guard let usage = button.identity.consumerUsage else {
      throw SimulatorHIDError.notImplementedOnDTUHIDTransport(
        operation: "sendButton(.applePay) — Apple Pay is a double side-button press, not a single HID usage; send two .sideButton presses instead")
    }
    let state: HIDButtonState = direction == .down ? .down : .up
    try await send(
      messageType: "IndigoButtonEvent",
      payload: IndigoButtonEvent(usagePage: UInt64(usage.page), usageCode: UInt64(usage.code), state: state))
  }

  func sendKeyboard(direction: SimulatorHIDDirection, keyCode: UInt32) async throws {
    let state: HIDButtonState = direction == .down ? .down : .up
    try await send(
      messageType: "IndigoKeyboardButtonEvent",
      payload: IndigoKeyboardButtonEvent(usageCode: UInt64(keyCode), state: state))
  }

  /// Sends the keyboard usage the tvOS focus engine consumes. `dtuhidd` also advertises
  /// `com.apple.coredevice.feature.remote.hid.tvremote`, whose accepted usages are undocumented.
  func sendRemoteButton(direction: SimulatorHIDDirection, button: SimulatorHIDRemoteButton) async throws {
    try await sendKeyboard(direction: direction, keyCode: button.keyboardUsage)
  }

  // MARK: - Sending

  /// Nothing suspends between a contact tracker assigning an event type and the write, so concurrent
  /// sends cannot deliver an `.end` ahead of the `.start` it followed.
  private func send(messageType: String, payload: some Encodable) async throws {
    try connection.write(messageType: messageType, payload: payload)
    await connection.awaitSendBarrier()
  }
}
