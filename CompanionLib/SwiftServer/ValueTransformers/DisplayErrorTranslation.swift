/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBSimulatorControl
import GRPCCore

/// Maps the errors of choosing a display, and of reaching the one chosen, onto the status a client sees.
/// Every handler that takes a display uses it, so a display gets the same answer whichever command named
/// it: an id the simulator does not have, a point off the display, or a backend that cannot read the display
/// named, is the caller's mistake; a display that cannot be used right now is the device's state; and
/// routing this simulator can never do is unimplemented, however often it is asked.
enum DisplayErrorTranslation {

  /// Runs `body`, rethrowing a display error as its status. Any other error is rethrown untouched, for
  /// `ErrorMapping` to report as it always has.
  static func translatingErrors<R>(_ body: () async throws -> R) async throws -> R {
    do {
      return try await body()
    } catch {
      guard let rpcError = status(for: error) else {
        throw error
      }
      throw rpcError
    }
  }

  /// The status for a display error, or nil when `error` is not one.
  static func status(for error: any Error) -> RPCError? {
    let code: RPCError.Code
    switch error {
    case let error as SimulatorDisplayError:
      code = Self.code(for: error)
    case let error as SimulatorDisplayInteractionError:
      code = Self.code(for: error)
    case SimulatorHIDError.touchUnsupportedOnAppleTV, SimulatorHIDError.touchTargetUnsupportedOnIndigoTransport:
      // A target without a touchscreen, or a transport that cannot address one, has no display to route to.
      code = .unimplemented
    case IDBCommandError.displayIdUnreported:
      // The runtime does not say which display to hit-test, and asking again will not change that.
      code = .unimplemented
    case UIAutomationError.operationUnsupported:
      // Only the describe-point display path raises it here: the caller chose a backend that cannot hit-test
      // the display it named (any display but the device's only integrated one is read by the AX backend
      // only), just as naming the ax backend beside a bundle id is refused.
      code = .invalidArgument
    default:
      return nil
    }
    return RPCError(code: code, message: error.localizedDescription)
  }

  private static func code(for error: SimulatorDisplayError) -> RPCError.Code {
    switch error {
    case .unknownDisplay: .invalidArgument
    case .touchRoutingUnsupported: .unimplemented
    default: .failedPrecondition
    }
  }

  private static func code(for error: SimulatorDisplayInteractionError) -> RPCError.Code {
    switch error {
    case .unsupportedCapability: .unimplemented
    case .inactiveDisplay, .missingMapping: .failedPrecondition
    case .invalidPoint: .invalidArgument
    }
  }
}
