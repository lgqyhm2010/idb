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
    var touchTarget: SimulatorTouchTarget?
    // An edge selection is scoped to the stream for the same reason.
    var edge = SimulatorHIDEdge.none
    for try await request in requestStream {
      if case let .display(display) = request.event {
        touchTarget = try await resolveTouchTarget(display)
        continue
      }
      if case let .edge(selection) = request.event {
        edge = try Self.fbSimulatorHIDEdge(from: selection.edge)
        continue
      }
      let event = try Self.fbSimulatorHIDEvent(from: request, edge: edge)
      try await commandExecutor.hid(event, touchTarget: touchTarget)
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
    do {
      return try await commandExecutor.touch_target(displayUniqueID: Self.displayUniqueID(from: display))
    } catch let error as SimulatorDisplayError {
      throw RPCError(code: Self.rpcCode(for: error), message: error.localizedDescription)
    } catch let error as SimulatorHIDError {
      throw RPCError(code: Self.rpcCode(forHIDError: error), message: error.localizedDescription)
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

  /// `edge` tags the touches and swipes the request carries; it comes from an earlier `HIDEdge` in the
  /// stream, since the request itself has nowhere to say it.
  static func fbSimulatorHIDEvent(from request: Idb_HIDEvent, edge: SimulatorHIDEdge = .none) throws -> SimulatorHIDEvent {
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
          return .touch(direction: .up, x: touch.point.x, y: touch.point.y, edge: edge)
        case .down:
          return .touch(direction: .down, x: touch.point.x, y: touch.point.y, edge: edge)
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
        duration: swipe.duration,
        edge: edge)

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

    case .edge:
      throw RPCError(code: .invalidArgument, message: "An edge selection tags the touches after it and is not an event itself")

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
