/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBSimulatorControl
import GRPCCore

/// Shared gRPC status translation for display inventory, HID and scoped accessibility reads.
enum DisplayErrorTranslation {
  static func translatingErrors<R>(_ body: () async throws -> R) async throws -> R {
    do { return try await body() } catch {
      guard let translated = status(for: error) else { throw error }
      throw translated
    }
  }

  static func status(for error: any Error) -> RPCError? {
    let code: RPCError.Code
    switch error {
    case SimulatorDisplayError.unknownDisplay:
      code = .invalidArgument
    case is SimulatorDisplayError:
      code = .failedPrecondition
    case SimulatorDisplayInteractionError.invalidPoint, SimulatorDisplayInteractionError.nonFinitePoint:
      code = .invalidArgument
    case SimulatorDisplayInteractionError.inactiveDisplay, SimulatorDisplayInteractionError.missingMapping:
      code = .failedPrecondition
    case SimulatorHIDStreamError.displaySelectionDuringTouch:
      code = .invalidArgument
    case SimulatorHIDError.touchUnsupportedOnAppleTV:
      code = .unimplemented
    case UIAutomationError.operationUnsupported:
      code = .invalidArgument
    default:
      if unsupportedSimulatorCapability(in: error) != nil { code = .unimplemented }
      else if SimulatorFailureKind(error) == .notReady { code = .failedPrecondition }
      else { return nil }
    }
    return RPCError(code: code, message: error.localizedDescription)
  }
}
