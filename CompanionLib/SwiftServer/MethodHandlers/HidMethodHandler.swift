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
    // A display selection routes the touches after it in this stream, and only in this stream: the HID
    // connection is shared by every caller, so the selection cannot live on it.
    var routing = TouchRouting()
    // An edge selection is scoped to the stream for the same reason.
    var edge = SimulatorHIDEdge.none
    for try await message in requestStream {
      if case let .display(display) = message.event {
        guard !routing.touchIsDown else {
          throw RPCError(
            code: .invalidArgument,
            message: "A display cannot be selected while a touch is down: lift it first, so it ends where it started")
        }
        let target = try await resolveTouchTarget(display)
        routing.select(display, target: target)
        continue
      }
      if case let .edge(selection) = message.event {
        edge = try Self.fbSimulatorHIDEdge(from: selection.edge)
        continue
      }
      let request = try Self.request(from: message, edge: edge)
      switch request {
      case let .input(event):
        if let selection = routing.selectionToResolve(before: event) {
          let target = try await resolveTouchTarget(selection)
          routing.resolved(target)
        }
        try await send(event, touchTarget: routing.target)
      case let .orientation(orientation):
        // Interface numbering is what `idb`'s HID stream has always carried.
        try await commandExecutor.set_orientation(orientation, convention: .interface)
      case .shake:
        try await commandExecutor.shake()
      case let .hinge(angle):
        try await commandExecutor.set_hinge_angle(angle)
      }
      routing.sent(request)
    }
    return .init()
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

  private func resolveTouchTarget(_ display: Idb_HIDEvent.HIDDisplay) async throws -> SimulatorTouchTarget {
    try await DisplayErrorTranslation.translatingErrors {
      try await commandExecutor.touch_target(displayUniqueID: Self.displayUniqueID(from: display))
    }
  }

  /// A routed event can fail over the display it is routed to, which is the device's state or a
  /// transport that cannot route, not an internal error. An unrouted event fails as it always has.
  private func send(_ event: SimulatorHIDEvent, touchTarget: SimulatorTouchTarget?) async throws {
    guard let touchTarget else {
      try await commandExecutor.hid(event)
      return
    }
    try await DisplayErrorTranslation.translatingErrors {
      try await commandExecutor.hid(event, touchTarget: touchTarget)
    }
  }

  /// Where one stream's touches go after a display selection. The target is resolved when the display
  /// is selected, and again before the next touch once a rotation or a hinge change has moved the
  /// display's geometry or which display is lit, but never while a contact is down: a contact goes to
  /// one touchscreen from its start to its end.
  struct TouchRouting {
    private(set) var selection: Idb_HIDEvent.HIDDisplay?
    private(set) var target: SimulatorTouchTarget?
    private(set) var touchIsDown = false
    private var targetIsStale = false

    mutating func select(_ display: Idb_HIDEvent.HIDDisplay, target: SimulatorTouchTarget) {
      selection = display
      resolved(target)
    }

    /// The selection to resolve again before sending `event`, if its target has gone stale.
    func selectionToResolve(before event: SimulatorHIDEvent) -> Idb_HIDEvent.HIDDisplay? {
      guard targetIsStale, !touchIsDown, Self.carriesTouches(event) else {
        return nil
      }
      return selection
    }

    mutating func resolved(_ target: SimulatorTouchTarget) {
      self.target = target
      targetIsStale = false
    }

    mutating func sent(_ request: Request) {
      // Only a bare touch leaves a contact down: a tap, swipe or pinch lifts every contact it starts.
      if case let .input(.touch(direction, _, _, _)) = request {
        touchIsDown = direction == .down
      }
      if Self.movesDisplays(request) {
        targetIsStale = true
      }
    }

    static func carriesTouches(_ event: SimulatorHIDEvent) -> Bool {
      switch event {
      case .touch, .twoFingerTouch: true
      case let .composite(events): events.contains(where: carriesTouches)
      default: false
      }
    }

    /// Rotation and the hinge are device actions rather than HID input, so they arrive as requests of
    /// their own.
    static func movesDisplays(_ request: Request) -> Bool {
      switch request {
      case .orientation, .hinge: true
      case .input, .shake: false
      }
    }
  }

  /// An empty identity selects the active integrated display.
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
