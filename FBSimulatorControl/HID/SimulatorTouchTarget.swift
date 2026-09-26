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
  /// The display's CoreDevice id, which an accessibility hit-test on it needs; nil if not reported.
  public var displayId: UInt32? = nil

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

  /// A point in the display's interface orientation as a point on its unrotated panel — the space an
  /// accessibility hit-test on the display is asked in, while the elements it answers with report
  /// frames in the interface orientation (measured on the iPhone Duo's inner display).
  public func panelPoint(for point: CGPoint) -> CGPoint {
    let ratio = digitizerRatio(for: point)
    return CGPoint(x: ratio.x * pixelSize.width / CGFloat(scale), y: ratio.y * pixelSize.height / CGFloat(scale))
  }

  /// An edge of the display's interface orientation, as the edge of its unrotated panel the digitizer
  /// reads it on: the same rotation `digitizerRatio(for:)` carries points through, so a contact's
  /// edge stays the one its coordinates start at.
  public func digitizerEdge(for edge: SimulatorHIDEdge) -> SimulatorHIDEdge {
    switch (rotation, edge) {
    case (_, .none), (.upright, _): edge
    case (.clockwise, .top): .left
    case (.clockwise, .left): .bottom
    case (.clockwise, .bottom): .right
    case (.clockwise, .right): .top
    case (.upsideDown, .top): .bottom
    case (.upsideDown, .left): .right
    case (.upsideDown, .bottom): .top
    case (.upsideDown, .right): .left
    case (.counterclockwise, .top): .right
    case (.counterclockwise, .left): .top
    case (.counterclockwise, .bottom): .left
    case (.counterclockwise, .right): .bottom
    }
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
    var target = SimulatorTouchTarget(
      displayUniqueID: display.uniqueID,
      digitizerTarget: touchscreen.digitizerTarget,
      pixelSize: display.bounds.size,
      scale: display.scale,
      rotation: display.rotation)
    target.displayId = display.displayId
    return target
  }
}

/// Which touchscreen covers which display. Universal HID takes about a second to list it, which a
/// touch cannot afford to pay each time, so a listing is kept and read again only when the displays
/// differ from those it was read against: their identities, and which of them are lit, since a
/// foldable can attach a display's touchscreen only while that display is lit and number it afresh
/// when it does. Rotation and geometry, which do change between touches, are read afresh on every
/// resolution and never decide whether the listing is kept.
///
/// A listing is only kept against displays read both before and after it: a fold landing while it
/// is read would otherwise file the new arrangement's numbering under the old one's displays, and
/// every touch resolved from it would reach a digitizer target that no longer covers the display.
///
/// A reboot numbers the touchscreens afresh behind displays that look the same, which nothing read
/// here can show, so the simulator changing state has to `forget()` the listing.
///
/// A kept listing can still be stale in ways the displays do not show, so a display that a kept
/// listing finds no touchscreen for is looked up once more in a fresh one before that is reported.
///
/// The listing in flight is shared, so streams resolving at the same time share one read rather
/// than each paying for it; a read that fails is forgotten.
actor SimulatorTouchscreenTopology {
  /// The displays a listing was read against.
  private struct Key: Equatable {
    let displayIDs: Set<String>
    let activeDisplayIDs: Set<String>

    init(_ displays: [SimulatorDisplay]) {
      displayIDs = Set(displays.map(\.uniqueID))
      activeDisplayIDs = Set(displays.filter(\.isActive).map(\.uniqueID))
    }
  }

  /// A touchscreen listing, and the displays read just after it, which have the key of those read
  /// just before it.
  private struct Listing: Sendable {
    let touchscreens: [SimulatorTouchscreen]
    let displays: [SimulatorDisplay]
  }

  private enum Kept {
    case reading(Key, Task<Listing, Error>)
    case read(Key, Listing)
  }

  /// How many times a listing is read before displays that change during every read are reported
  /// rather than a listing that could belong to either arrangement.
  static let readAttempts = 2

  private var kept: Kept?

  /// Drops the kept listing, so the next resolution reads one afresh.
  func forget() {
    kept = nil
  }

  /// Resolves the touchscreen of a display; nil selects the active integrated display.
  /// `readDisplays` snapshots the displays and `readTouchscreens` lists the touchscreens afresh.
  func touchTarget(
    displayUniqueID: String?,
    readDisplays: @escaping @Sendable () async throws -> [SimulatorDisplay],
    readTouchscreens: @escaping @Sendable () async throws -> [SimulatorTouchscreen]
  ) async throws -> SimulatorTouchTarget {
    let displays = try await readDisplays()
    let key = Key(displays)
    let (listing, wasKept) = try await self.listing(
      for: key, refresh: false, readDisplays: readDisplays, readTouchscreens: readTouchscreens)
    do {
      // A listing kept from an earlier call is resolved against the displays just read, whose rotation
      // and geometry may have moved since; one read by this call against the displays read after it.
      return try SimulatorTouchTarget.resolve(
        displayUniqueID: displayUniqueID, displays: wasKept ? displays : listing.displays,
        touchscreens: listing.touchscreens)
    } catch SimulatorDisplayError.noTouchscreen(_) where wasKept {
      let (fresh, _) = try await self.listing(
        for: key, refresh: true, readDisplays: readDisplays, readTouchscreens: readTouchscreens)
      return try SimulatorTouchTarget.resolve(
        displayUniqueID: displayUniqueID, displays: fresh.displays, touchscreens: fresh.touchscreens)
    }
  }

  /// The listing for `key`, and whether it was kept from an earlier call rather than read for, or
  /// while, this one. `refresh` reads afresh even when a listing for `key` is kept.
  private func listing(
    for key: Key, refresh: Bool,
    readDisplays: @escaping @Sendable () async throws -> [SimulatorDisplay],
    readTouchscreens: @escaping @Sendable () async throws -> [SimulatorTouchscreen]
  ) async throws -> (listing: Listing, wasKept: Bool) {
    if !refresh {
      switch kept {
      case let .read(keptKey, listing)? where keptKey == key:
        return (listing, true)
      case let .reading(keptKey, task)? where keptKey == key:
        return (try await task.value, false)
      default:
        break
      }
    }
    let task = Task {
      try await Self.read(from: key, readDisplays: readDisplays, readTouchscreens: readTouchscreens)
    }
    kept = .reading(key, task)
    // The actor may have been re-entered during the await, so only settle the read this call started.
    do {
      let listing = try await task.value
      if case let .reading(_, current)? = kept, current == task {
        kept = .read(Key(listing.displays), listing)
      }
      return (listing, false)
    } catch {
      if case let .reading(_, current)? = kept, current == task {
        kept = nil
      }
      throw error
    }
  }

  /// Lists the touchscreens between two display snapshots, reading again when the displays changed
  /// in between, since the listing could then belong to either arrangement.
  private static func read(
    from key: Key,
    readDisplays: @Sendable () async throws -> [SimulatorDisplay],
    readTouchscreens: @Sendable () async throws -> [SimulatorTouchscreen]
  ) async throws -> Listing {
    var before = key
    for _ in 0..<readAttempts {
      let touchscreens = try await readTouchscreens()
      let displays = try await readDisplays()
      let after = Key(displays)
      if after == before {
        return Listing(touchscreens: touchscreens, displays: displays)
      }
      before = after
    }
    throw SimulatorDisplayError.changed
  }
}
