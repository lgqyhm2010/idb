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

  let commandExecutor: IDBCommandExecutor

  func handle(requestStream: RequestStreamReader<Idb_HIDEvent>, context: ServerContext) async throws -> Idb_HIDResponse {
    // A display selection routes the touches after it in this stream, and only in this stream: the HID
    // connection is shared by every caller, so the selection cannot live on it.
    var routing = TouchRouting()
    for try await request in requestStream {
      if case let .display(display) = request.event {
        guard !routing.touchIsDown else {
          throw RPCError(
            code: .invalidArgument,
            message: "A display cannot be selected while a touch is down: lift it first, so it ends where it started")
        }
        let target = try await resolveTouchTarget(display)
        routing.select(display, target: target)
        continue
      }
      let event = try Self.fbSimulatorHIDEvent(from: request)
      if let selection = routing.selectionToResolve(before: event) {
        let target = try await resolveTouchTarget(selection)
        routing.resolved(target)
      }
      try await commandExecutor.hid(event, touchTarget: routing.target)
      routing.sent(event)
    }
    return .init()
  }

  private func resolveTouchTarget(_ display: Idb_HIDEvent.HIDDisplay) async throws -> SimulatorTouchTarget {
    do {
      return try await commandExecutor.touch_target(displayUniqueID: Self.displayUniqueID(from: display))
    } catch let error as SimulatorDisplayError {
      throw RPCError(code: Self.rpcCode(for: error), message: error.localizedDescription)
    } catch let error as SimulatorHIDError {
      throw RPCError(code: Self.rpcCode(forHIDError: error), message: error.localizedDescription)
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

    mutating func sent(_ event: SimulatorHIDEvent) {
      // Only a bare touch leaves a contact down: a tap, swipe or pinch lifts every contact it starts.
      if case let .touch(direction, _, _, _) = event {
        touchIsDown = direction == .down
      }
      if Self.movesDisplays(event) {
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

    static func movesDisplays(_ event: SimulatorHIDEvent) -> Bool {
      switch event {
      case .deviceOrientation, .hinge: true
      case let .composite(events): events.contains(where: movesDisplays)
      default: false
      }
    }
  }

  /// An empty identity selects the active integrated display.
  static func displayUniqueID(from display: Idb_HIDEvent.HIDDisplay) -> String? {
    display.uniqueID.isEmpty ? nil : display.uniqueID
  }

  /// Naming a display that does not exist is the caller's mistake, and a runtime that cannot route by
  /// display never will; the rest describe the device's state.
  static func rpcCode(for error: SimulatorDisplayError) -> RPCError.Code {
    switch error {
    case .unknownDisplay: .invalidArgument
    case .touchRoutingUnsupported: .unimplemented
    default: .failedPrecondition
    }
  }

  /// A target without a touchscreen has no display to route touches to.
  static func rpcCode(forHIDError error: SimulatorHIDError) -> RPCError.Code {
    switch error {
    case .touchUnsupportedOnAppleTV: .unimplemented
    default: .internalError
    }
  }

  static func fbSimulatorHIDEvent(from request: Idb_HIDEvent) throws -> SimulatorHIDEvent {
    switch request.event {
    case let .press(press):
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
          return .touch(direction: .up, x: touch.point.x, y: touch.point.y)
        case .down:
          return .touch(direction: .down, x: touch.point.x, y: touch.point.y)
        case .UNRECOGNIZED:
          throw RPCError(code: .invalidArgument, message: "Unrecognized press.direction")
        }

      case .none:
        throw RPCError(code: .invalidArgument, message: "Unrecognized press.action")
      }

    case let .swipe(swipe):
      return SimulatorHIDEvent.swipe(
        swipe.start.x,
        yStart: swipe.start.y,
        xEnd: swipe.end.x,
        yEnd: swipe.end.y,
        delta: swipe.delta,
        duration: swipe.duration)

    case let .delay(delay):
      return SimulatorHIDEvent.delay(delay.duration)

    case let .pinch(pinch):
      let centerX = Double(pinch.center.x)
      let centerY = Double(pinch.center.y)
      let scale = pinch.scale
      let duration = pinch.duration > 0 ? pinch.duration : 0.5
      let radius = pinch.radius > 0 ? pinch.radius : 100.0
      return SimulatorHIDEvent.pinchAt(x: centerX, y: centerY, scale: scale, duration: duration, radius: radius)

    case let .orientation(orientation):
      guard let deviceOrientation = fbSimulatorHIDDeviceOrientation(from: orientation.orientation) else {
        throw RPCError(code: .invalidArgument, message: "Unrecognized orientation type")
      }
      return .deviceOrientation(deviceOrientation)

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

    case .none:
      throw RPCError(code: .invalidArgument, message: "Unrecognized request.event")
    }
  }

  private static func fbSimulatorHIDDeviceOrientation(from request: Idb_HIDEvent.HIDOrientationType) -> SimulatorHIDDeviceOrientation? {
    switch request {
    case .portrait:
      return .portrait
    case .portraitUpsideDown:
      return .portraitUpsideDown
    case .landscapeLeft:
      return .landscapeLeft
    case .landscapeRight:
      return .landscapeRight
    case .UNRECOGNIZED:
      return nil
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
    case .UNRECOGNIZED:
      return nil
    }
  }
}
