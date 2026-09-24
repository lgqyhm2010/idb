/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import Foundation

/**
 The touchscreen of one display, resolved into what the digitizer needs to address it: the explicit
 digitizer target, and the geometry touches in points are normalized against.

 Touches aimed at a display are given in its interface orientation, the space a screenshot of it is
 in. Its digitizer reads its unrotated panel instead, which on a foldable's inner display is upside
 down in portrait, so the point is carried back through the display's rotation before normalizing.

 Absent everywhere touches are sent, a touch goes to digitizer target zero, the main-screen alias,
 normalized against the device type's main screen. That is the only behaviour a single-display
 simulator can have, and the wrong one for a foldable whose lit display is not the main one.
 */
public struct SimulatorTouchTarget: Equatable, Sendable {
  public let displayUniqueID: String
  /// The explicit target the digitizer service accepts, from `SimulatorTouchscreen.digitizerTarget`.
  public let digitizerTarget: UInt32
  /// The display's size in its unrotated pixel space, the space the main screen's touches are
  /// normalized in too.
  public let pixelSize: CGSize
  public let scale: Double
  /// The interface rotation relative to the unrotated panel.
  public let rotation: SimulatorDisplayRotation

  public init(
    displayUniqueID: String, digitizerTarget: UInt32, pixelSize: CGSize, scale: Double,
    rotation: SimulatorDisplayRotation = .upright
  ) {
    self.displayUniqueID = displayUniqueID
    self.digitizerTarget = digitizerTarget
    self.pixelSize = pixelSize
    self.scale = scale
    self.rotation = rotation
  }

  /// A point in the display's interface orientation, in points, as a fraction of its unrotated panel.
  /// The inverse of the orientation a screenshot of the display applies (EXIF 1, 6, 3 and 8).
  public func digitizerRatio(for point: CGPoint) -> CGPoint {
    let width = pixelSize.width / CGFloat(scale)
    let height = pixelSize.height / CGFloat(scale)
    let panel: CGPoint
    switch rotation {
    case .upright: panel = point
    case .clockwise: panel = CGPoint(x: point.y, y: height - point.x)
    case .upsideDown: panel = CGPoint(x: width - point.x, y: height - point.y)
    case .counterclockwise: panel = CGPoint(x: width - point.y, y: point.x)
    }
    return CGPoint(x: panel.x / width, y: panel.y / height)
  }

  /// Joins a display snapshot to the touchscreen listing. `displayUniqueID` nil selects the active
  /// integrated display. Every way the join can fail is an error rather than a fall back to the main
  /// screen: a touch that lands somewhere other than where it was aimed reports success and changes
  /// nothing the caller can see.
  static func resolve(
    displayUniqueID: String?, displays: [SimulatorDisplay], touchscreens: [SimulatorTouchscreen]
  ) throws -> SimulatorTouchTarget {
    let display: SimulatorDisplay
    if let displayUniqueID {
      guard let named = displays.first(where: { $0.uniqueID == displayUniqueID }) else {
        throw SimulatorDisplayError.unknownDisplay(displayUniqueID, known: displays.map(\.uniqueID))
      }
      display = named
    } else {
      display = try SimulatorDisplayCommands.activeIntegratedDisplay(in: displays)
    }
    guard display.isActive else {
      throw SimulatorDisplayError.inactiveDisplay(display.uniqueID)
    }
    guard let touchscreen = touchscreens.first(where: { $0.displayUniqueID == display.uniqueID }) else {
      throw SimulatorDisplayError.noTouchscreen(display.uniqueID)
    }
    return SimulatorTouchTarget(
      displayUniqueID: display.uniqueID,
      digitizerTarget: touchscreen.digitizerTarget,
      pixelSize: display.bounds.size,
      scale: display.scale,
      rotation: display.rotation)
  }
}

/// Which touchscreen covers which display. Universal HID takes about a second to list it, which a
/// touch cannot afford to pay each time, and it changes only with the displays themselves, so it is
/// listed again only when the display identities differ from those it was listed against. Activity,
/// rotation and geometry, which do change between touches, are read afresh on every resolution.
///
/// The listing in flight is what is kept, so streams resolving at the same time share one read
/// rather than each paying for it; a read that fails is forgotten.
actor SimulatorTouchscreenTopology {
  private var listing: (displayIDs: Set<String>, task: Task<[SimulatorTouchscreen], Error>)?

  func touchscreens(
    forDisplays displayIDs: Set<String>, read: @escaping @Sendable () async throws -> [SimulatorTouchscreen]
  ) async throws -> [SimulatorTouchscreen] {
    if let listing, listing.displayIDs == displayIDs {
      return try await listing.task.value
    }
    let task = Task { try await read() }
    listing = (displayIDs, task)
    do {
      return try await task.value
    } catch {
      // The actor may have been re-entered during the await, so only forget the listing that failed.
      if listing?.task == task {
        listing = nil
      }
      throw error
    }
  }
}
