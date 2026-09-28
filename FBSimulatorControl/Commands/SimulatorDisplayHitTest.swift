/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

/// Where a point read aimed at a display is hit-tested.
public enum SimulatorDisplayHitTest: Equatable, Sendable {
  /// The device's only integrated display, reached as a plain point read exactly as without a display.
  case mainScreen
  /// Another display: hit-tested by its CoreDevice display id at the point on its unrotated panel.
  case display(SimulatorDisplay)
}

extension SimulatorDisplayCommands {

  /// Where a point read aimed at a display is hit-tested; nil aims it at the active integrated display.
  /// Only the display report is read: a hit-test needs no touchscreen, so any lit display can be named.
  public func hitTestTarget(displayUniqueID: String?) async throws -> SimulatorDisplayHitTest {
    do {
      return try Self.hitTestTarget(displayUniqueID: displayUniqueID, in: await list())
    } catch SimulatorCoreDeviceError.unsupported {
      // Internal to this module, so callers could only report it as an unexplained failure.
      throw SimulatorDisplayInteractionError.unsupportedCapability("display reports")
    }
  }

  /// A named display has to be listed and lit, integrated or not. The device's only integrated display
  /// is the one a plain point read reaches, so naming it hit-tests the main screen.
  static func hitTestTarget(displayUniqueID: String?, in displays: [SimulatorDisplay]) throws -> SimulatorDisplayHitTest {
    let display: SimulatorDisplay
    if let displayUniqueID {
      guard let named = displays.first(where: { $0.uniqueID == displayUniqueID }) else {
        throw SimulatorDisplayError.unknownDisplay(displayUniqueID, known: displays.map(\.uniqueID))
      }
      guard named.isActive else { throw SimulatorDisplayError.inactiveDisplay(displayUniqueID) }
      display = named
    } else {
      display = try activeIntegratedDisplay(in: displays)
    }
    return display.isIntegrated && displays.filter(\.isIntegrated).count == 1 ? .mainScreen : .display(display)
  }
}
