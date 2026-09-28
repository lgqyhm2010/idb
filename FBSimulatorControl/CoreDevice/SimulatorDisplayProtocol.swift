/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import XPC

/// The `displayinfo` feature: what the provider reports about each display, and what a current
/// report has to say before a display can be selected from it.
enum SimulatorDisplayProtocol {
  static let service = "com.apple.coredevice.feature.getdisplayinfo"
  static let action = "com.apple.coredevice.action.displayinfo"

  /// The output as the provider sends it. Activity and stable identity are optional only because
  /// older providers omit both from every display; see `snapshot`. Some providers identify every
  /// display but report which is lit only as a backlight state (iOS 27.0, measured).
  struct Report: Decodable {
    struct Record: Decodable {
      let uniqueId: String?
      let name: String
      let active: Bool?
      let backlightState: String?
      let primary: Bool
      let bounds: [[Double]]
      let pointScale: Int64
      let currentOrientation: SimulatorDisplayRotation
      let type: [String: XPCValue]
      let displayId: UInt64?
    }

    let current: Bool
    let displays: [Record]
  }

  /// Whether a report can select a display, or comes from a provider that cannot say which is active,
  /// or has only one integrated display and so nothing to select.
  enum Snapshot: Equatable {
    case displays([SimulatorDisplay])
    case legacyProvider
    case soleIntegratedDisplay
  }

  private static let maximumDisplays = 32
  private static let maximumStringLength = 1024

  /// A report with one integrated display has nothing to select, whatever it says about identity
  /// and activity. Otherwise a report with identity and activity yields displays, and one that omits
  /// both from every display is a legacy provider. A report that has them on some displays but not
  /// others is malformed.
  static func snapshot(_ reply: xpc_object_t) throws -> Snapshot {
    let report = try validated(CoreDeviceReply.decode(Report.self, from: reply))
    let integrated = try report.displays.filter { try validated($0).integrated }
    if integrated.count == 1 {
      return .soleIntegratedDisplay
    }
    let legacy = isLegacy(report)
    guard legacy, !report.displays.isEmpty else {
      return .displays(try displays(in: report))
    }
    return .legacyProvider
  }

  /// A current report's displays. A legacy provider's are named `legacy-<displayId>`, which no
  /// touchscreen covers, so they can be listed but not routed to.
  static func displays(_ reply: xpc_object_t) throws -> [SimulatorDisplay] {
    try displays(in: validated(CoreDeviceReply.decode(Report.self, from: reply)))
  }

  private static func isLegacy(_ report: Report) -> Bool {
    report.displays.allSatisfy { $0.active == nil && $0.uniqueId == nil }
  }

  private static func validated(_ report: Report) throws -> Report {
    guard report.current else { throw SimulatorCoreDeviceError.malformed("Report is not current") }
    guard report.displays.count <= maximumDisplays else { throw SimulatorCoreDeviceError.malformed("Too many displays") }
    return report
  }

  private static func displays(in report: Report) throws -> [SimulatorDisplay] {
    let legacy = isLegacy(report)
    let hasLayoutActivity = report.displays.contains { $0.active != nil }
    let soleIntegrated = try report.displays.filter { try validated($0).integrated }.count == 1
    var identifiers: Set<String> = []
    var displays: [SimulatorDisplay] = []
    for (index, record) in report.displays.enumerated() {
      let validated = try validated(record)
      let identity = legacy ? "legacy-\(record.displayId ?? UInt64(index))" : record.uniqueId
      guard let id = identity, !id.isEmpty, id.utf8.count <= maximumStringLength, identifiers.insert(id).inserted else {
        throw SimulatorCoreDeviceError.malformed("Duplicate or empty display identity")
      }
      let active = try activity(
        of: record, integrated: validated.integrated, soleIntegrated: soleIntegrated, hasLayoutActivity: hasLayoutActivity)
      guard !active || !validated.bounds.isEmpty else { throw SimulatorCoreDeviceError.malformed("Active display has empty bounds") }
      displays.append(
        SimulatorDisplay(
          uniqueID: id, name: record.name, isActive: active, isPrimary: record.primary, isIntegrated: validated.integrated,
          bounds: validated.bounds, scale: Double(record.pointScale), rotation: record.currentOrientation,
          displayId: record.displayId.flatMap(UInt32.init(exactly:))))
    }
    return displays.sorted { $0.uniqueID < $1.uniqueID }
  }

  /// Layout activity is authoritative when the report carries it, and then every display must.
  /// Without it the backlight says which display is lit. When neither does, the one integrated
  /// display of a device that has one is its screen; with several there is no telling which is lit.
  private static func activity(of record: Report.Record, integrated: Bool, soleIntegrated: Bool, hasLayoutActivity: Bool) throws -> Bool {
    if hasLayoutActivity {
      guard let active = record.active else { throw SimulatorCoreDeviceError.malformed("Display has no activity") }
      return active
    }
    switch record.backlightState {
    case "activeOn", "activeDimmed": return true
    case "off", "inactiveOn": return false
    default:
      guard integrated else { return false }
      guard soleIntegrated else { throw SimulatorCoreDeviceError.malformed("Display has no activity") }
      return true
    }
  }

  /// The fields every record has to satisfy, legacy or not.
  private static func validated(_ record: Report.Record) throws -> (bounds: CGRect, integrated: Bool) {
    guard record.name.utf8.count <= maximumStringLength else { throw SimulatorCoreDeviceError.malformed("name") }
    guard record.pointScale > 0 else { throw SimulatorCoreDeviceError.malformed("Invalid display scale") }
    guard record.type.count == 1 else { throw SimulatorCoreDeviceError.malformed("Invalid display type") }
    return (try rectangle(record.bounds), record.type["integrated"] != nil)
  }

  /// Bounds arrive as `[[x, y], [width, height]]`.
  private static func rectangle(_ value: [[Double]]) throws -> CGRect {
    guard value.count == 2, value[0].count == 2, value[1].count == 2 else {
      throw SimulatorCoreDeviceError.malformed("Invalid bounds")
    }
    let (x, y, width, height) = (value[0][0], value[0][1], value[1][0], value[1][1])
    guard [x, y, width, height].allSatisfy(\.isFinite) else { throw SimulatorCoreDeviceError.malformed("Non-finite coordinate") }
    guard width >= 0, height >= 0 else { throw SimulatorCoreDeviceError.malformed("Negative size") }
    return CGRect(x: x, y: y, width: width, height: height)
  }
}
