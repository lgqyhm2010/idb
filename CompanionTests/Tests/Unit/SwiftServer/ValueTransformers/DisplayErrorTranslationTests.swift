/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
import FBSimulatorControl
import Foundation
import GRPCCore
import XCTest

final class DisplayErrorTranslationTests: XCTestCase {
  func testDisplayFailuresKeepActionableStatuses() {
    let cases: [(any Error, RPCError.Code)] = [
      (SimulatorDisplayError.unknownDisplay("missing", known: ["inner"]), .invalidArgument),
      (SimulatorDisplayError.changed, .failedPrecondition),
      (SimulatorDisplayError.transitioning, .failedPrecondition),
      (SimulatorDisplayInteractionError.inactiveDisplay("cover"), .failedPrecondition),
      (SimulatorDisplayInteractionError.missingMapping("inner"), .failedPrecondition),
      (SimulatorDisplayInteractionError.unsupportedCapability("display identities"), .unimplemented),
      (SimulatorDisplayInteractionError.nonFinitePoint(CGPoint(x: Double.nan, y: 0)), .invalidArgument),
      (SimulatorHIDStreamError.displaySelectionDuringTouch, .invalidArgument),
      (SimulatorHIDError.touchUnsupportedOnAppleTV, .unimplemented),
    ]
    for (error, expected) in cases {
      let translated = DisplayErrorTranslation.status(for: error)
      XCTAssertEqual(translated?.code, expected)
      XCTAssertEqual(translated?.message, error.localizedDescription)
    }
  }

  func testUnrelatedErrorsAreNotReclassified() {
    XCTAssertNil(DisplayErrorTranslation.status(for: CancellationError()))
  }
}
