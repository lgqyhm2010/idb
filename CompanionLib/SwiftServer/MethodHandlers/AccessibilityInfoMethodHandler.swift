/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import FBSimulatorControl
import Foundation
import GRPCCore
import IDBGRPCSwift

/// Seam over the four `IDBCommandExecutor` reads this handler drives, so the request-to-options wiring
/// can be tested against a double.
protocol AccessibilityDescribing {
  func accessibility_describe(
    query: AccessibilityElementQuery,
    options: AccessibilityRequestOptions,
    backend: UIAutomationBackend
  ) async throws -> Data

  func accessibility_info_at_point(
    _ value: NSValue?,
    options: AccessibilityRequestOptions,
    backend: UIAutomationBackend
  ) async throws -> AccessibilityElementsResponse

  func accessibility_info_for_application(
    bundleID: String,
    options: AccessibilityRequestOptions,
    backend: UIAutomationBackend
  ) async throws -> AccessibilityElementsResponse

  func accessibility_info_at_point(
    _ point: CGPoint,
    onDisplay displayUniqueID: String?,
    options: AccessibilityRequestOptions,
    backend: UIAutomationBackend
  ) async throws -> AccessibilityElementsResponse
}

extension IDBCommandExecutor: AccessibilityDescribing {}

struct AccessibilityInfoMethodHandler {

  let commandExecutor: IDBCommandExecutor

  func handle(request: Idb_AccessibilityInfoRequest, context: ServerContext) async throws -> Idb_AccessibilityInfoResponse {
    try await Self.respond(to: request, using: commandExecutor)
  }

  /// Lifted out of `handle` so it can be tested without a `ServerContext`.
  static func respond(
    to request: Idb_AccessibilityInfoRequest,
    using commandExecutor: any AccessibilityDescribing
  ) async throws -> Idb_AccessibilityInfoResponse {
    try AccessibilityInfoRequestTranslation.validate(request)
    let format = AccessibilityInfoRequestTranslation.outputFormat(from: request.format)
    let backend = AccessibilityInfoRequestTranslation.backend(from: request.backend)
    // Built before the branch: both paths are reads of the same tree with the same options, so the
    // marker path honours the request's keys, profiling and frame coverage too.
    let options = try AccessibilityInfoRequestTranslation.options(from: request, format: format)
    // A marker selects a single element to describe; without one the request
    // describes the element at a point, or the whole frontmost app.
    if let query = AccessibilityInfoRequestTranslation.markerQuery(from: request) {
      let data = try await commandExecutor.accessibility_describe(query: query, options: options, backend: backend)
      return .with {
        $0.json = String(data: data, encoding: .utf8) ?? ""
      }
    }
    // A bundle id reads that application's whole tree; validate() has already refused it beside a point.
    let response: AccessibilityElementsResponse
    if request.hasDisplay {
      // validate() has already required a point beside a display. A display error gets the status it
      // gets on the HID stream, rather than reaching the client as an internal error.
      response = try await DisplayErrorTranslation.translatingErrors {
        try await commandExecutor.accessibility_info_at_point(
          CGPoint(x: request.point.x, y: request.point.y),
          onDisplay: HidMethodHandler.displayUniqueID(from: request.display), options: options, backend: backend)
      }
    } else if let bundleID = AccessibilityInfoRequestTranslation.bundleID(from: request) {
      response = try await commandExecutor.accessibility_info_for_application(
        bundleID: bundleID, options: options,
        backend: try AccessibilityInfoRequestTranslation.applicationBackend(from: request.backend))
    } else {
      response = try await commandExecutor.accessibility_info_at_point(
        AccessibilityInfoRequestTranslation.point(from: request), options: options, backend: backend)
    }
    let jsonData = try AccessibilityInfoRequestTranslation.responseJSON(from: response, format: format)
    return .with {
      $0.json = String(data: jsonData, encoding: .utf8) ?? ""
    }
  }
}
