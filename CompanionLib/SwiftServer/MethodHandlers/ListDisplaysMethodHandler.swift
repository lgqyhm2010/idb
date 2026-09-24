/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBSimulatorControl
import GRPCCore
import IDBGRPCSwift

struct ListDisplaysMethodHandler {
  let commandExecutor: IDBCommandExecutor

  func handle(request: Idb_ListDisplaysRequest, context: ServerContext) async throws -> Idb_ListDisplaysResponse {
    let (displays, touchscreenDisplayIDs) = try await commandExecutor.list_displays()
    return Self.response(displays: displays, touchscreenDisplayIDs: touchscreenDisplayIDs)
  }

  static func response(displays: [SimulatorDisplay], touchscreenDisplayIDs: Set<String>) -> Idb_ListDisplaysResponse {
    .with {
      $0.displays = displays.map { display in
        .with {
          $0.uniqueID = display.uniqueID
          $0.name = display.name
          $0.active = display.isActive
          $0.primary = display.isPrimary
          $0.integrated = display.isIntegrated
          $0.width = Double(display.bounds.width)
          $0.height = Double(display.bounds.height)
          $0.scale = display.scale
          $0.rotation = display.rotation.rawValue
          $0.touchscreen = touchscreenDisplayIDs.contains(display.uniqueID)
        }
      }
    }
  }
}
