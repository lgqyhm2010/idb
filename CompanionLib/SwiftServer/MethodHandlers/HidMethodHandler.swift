/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import FBSimulatorControl
import GRPCCore
import IDBGRPCSwift

struct HidMethodHandler {

  /// What a streamed `Idb_HIDEvent` asks of the simulator: input for the HID, or a device action.
  enum Request: Equatable {
    case input(SimulatorHIDEvent)
    case orientation(SimulatorHIDDeviceOrientation)
    case shake
    case hinge(SimulatorHingeAngle)
  }

  let commandExecutor: IDBCommandExecutor

  func handle(requestStream: RequestStreamReader<Idb_HIDEvent>, context: ServerContext) async throws -> Idb_HIDResponse {
    try await withRPCCancellation(context.cancellation) {
      var routing = StreamRouting()
      try await DisplayErrorTranslation.translatingErrors {
        try await commandExecutor.hid(stream: requestStream.compactMap { message -> SimulatorHIDStreamEvent? in
          if case let .display(display) = message.event {
            try routing.select(display)
            return .display(routing.binding)
          }
          if case let .edge(selection) = message.event {
            routing.edge = try Self.fbSimulatorHIDEdge(from: selection.edge)
            return nil
          }
          let request = try Self.request(from: message, edge: routing.edge)
          switch request {
          case let .input(event):
            routing.sent(event)
            return .input(event)
          case let .orientation(orientation):
            try routing.requireLiftedContacts()
            try await commandExecutor.set_orientation(orientation, convention: .interface)
          case .shake:
            try await commandExecutor.shake()
            return nil
          case let .hinge(angle):
            try routing.requireLiftedContacts()
            try await commandExecutor.set_hinge_angle(angle)
          }
          // The next gesture resolves fresh geometry after a requested rotation or hinge change.
          return .display(routing.binding)
        })
      }
    }
    return .init()
  }

  /// Selection and edge flags belong to this RPC, never the shared HID connection.
  struct StreamRouting {
    private(set) var binding = SimulatorHIDDisplayBinding.active
    var edge = SimulatorHIDEdge.none
    private(set) var touchIsDown = false
    private(set) var twoFingersAreDown = false

    func requireLiftedContacts() throws {
      guard !touchIsDown, !twoFingersAreDown else {
        throw SimulatorHIDStreamError.displaySelectionDuringTouch
      }
    }

    mutating func select(_ display: Idb_HIDEvent.HIDDisplay) throws {
      try requireLiftedContacts()
      binding = Self.binding(from: display)
    }

    static func binding(from display: Idb_HIDEvent.HIDDisplay) -> SimulatorHIDDisplayBinding {
      display.uniqueID.isEmpty ? .active : .display(uniqueID: display.uniqueID)
    }

    mutating func sent(_ event: SimulatorHIDEvent) {
      switch event {
      case let .touch(direction, _, _, _): touchIsDown = direction == .down
      case let .twoFingerTouch(direction, _, _): twoFingersAreDown = direction == .down
      case let .composite(events):
        for event in events { sent(event) }
      default: break
      }
    }
  }

  static func fbSimulatorHIDEdge(from wire: Idb_HIDEvent.HIDEdgeType) throws -> SimulatorHIDEdge {
    switch wire {
    case .edgeNone: .none
    case .edgeTop: .top
    case .edgeLeft: .left
    case .edgeBottom: .bottom
    case .edgeRight: .right
    case .UNRECOGNIZED:
      // Guessing an edge would start a system gesture the caller did not ask for.
      throw RPCError(code: .invalidArgument, message: "Unrecognized edge")
    }
  }

  /// The empty wire selector means ACTIVE for HID and accessibility reads.
  static func displayUniqueID(from display: Idb_HIDEvent.HIDDisplay) -> String? {
    display.uniqueID.isEmpty ? nil : display.uniqueID
  }

  /// `edge` tags the touches and swipes the request carries; it comes from an earlier `HIDEdge` in the
  /// stream, since the request itself has nowhere to say it.
  static func request(from request: Idb_HIDEvent, edge: SimulatorHIDEdge = .none) throws -> Request {
    switch request.event {
    case let .press(press):
      return .input(try pressEvent(from: press, edge: edge))

    case let .swipe(swipe):
      return .input(
        .swipe(
          swipe.start.x,
          yStart: swipe.start.y,
          xEnd: swipe.end.x,
          yEnd: swipe.end.y,
          delta: swipe.delta,
          duration: swipe.duration,
          edge: edge))

    case let .delay(delay):
      return .input(.delay(delay.duration))

    case let .pinch(pinch):
      let centerX = Double(pinch.center.x)
      let centerY = Double(pinch.center.y)
      let scale = pinch.scale
      let duration = pinch.duration > 0 ? pinch.duration : 0.5
      let radius = pinch.radius > 0 ? pinch.radius : 100.0
      return .input(.pinchAt(x: centerX, y: centerY, scale: scale, duration: duration, radius: radius))

    case let .orientation(orientation):
      return .orientation(try OrientationMethodHandler.orientation(orientation.orientation))

    case .shake:
      return .shake

    case let .hinge(hinge):
      do {
        return .hinge(try SimulatorHingeAngle(degrees: hinge.angle))
      } catch {
        throw RPCError(code: .invalidArgument, message: error.localizedDescription)
      }

    case .display:
      throw RPCError(code: .invalidArgument, message: "A display selection routes the events after it and is not an event itself")

    case .edge:
      throw RPCError(code: .invalidArgument, message: "An edge selection tags the touches after it and is not an event itself")

    case .none:
      throw RPCError(code: .invalidArgument, message: "Unrecognized request.event")
    }
  }

  private static func pressEvent(
    from press: Idb_HIDEvent.HIDPress, edge: SimulatorHIDEdge
  ) throws -> SimulatorHIDEvent {
    switch press.action.action {
    case let .key(key):
      switch press.direction {
      case .up:
        return .keyboard(direction: .up, keyCode: UInt32(key.keycode))
      case .down:
        return .keyboard(direction: .down, keyCode: UInt32(key.keycode))
      case .UNRECOGNIZED:
        throw RPCError(code: .invalidArgument, message: "Unrecognized press.direction")
      }

    case let .button(button):
      guard let hidButton = fbSimulatorHIDButton(from: button.button) else {
        throw RPCError(code: .invalidArgument, message: "Unrecognized hid button type")
      }
      switch press.direction {
      case .up:
        return .button(direction: .up, button: hidButton)
      case .down:
        return .button(direction: .down, button: hidButton)
      case .UNRECOGNIZED:
        throw RPCError(code: .invalidArgument, message: "Unrecognized press.direction")
      }

    case let .touch(touch):
      switch press.direction {
      case .up:
        return .touch(direction: .up, x: touch.point.x, y: touch.point.y, edge: edge)
      case .down:
        return .touch(direction: .down, x: touch.point.x, y: touch.point.y, edge: edge)
      case .UNRECOGNIZED:
        throw RPCError(code: .invalidArgument, message: "Unrecognized press.direction")
      }

    case .none:
      throw RPCError(code: .invalidArgument, message: "Unrecognized press.action")
    }
  }

  private static func fbSimulatorHIDButton(from request: Idb_HIDEvent.HIDButtonType) -> SimulatorHIDButton? {
    switch request {
    case .applePay:
      return .applePay
    case .home:
      return .homeButton
    case .lock:
      return .lock
    case .sideButton:
      return .sideButton
    case .siri:
      return .siri
    case .playPause:
      return .playPause
    case .volumeUp:
      return .volumeUp
    case .volumeDown:
      return .volumeDown
    case .eject:
      return .eject
    case .UNRECOGNIZED:
      return nil
    }
  }
}
