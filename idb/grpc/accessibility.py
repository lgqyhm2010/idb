#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


from idb.common.types import (
    ACTIVE_DISPLAY,
    AccessibilityApplication,
    AccessibilityInfoOptions,
    AccessibilityMarker,
    AccessibilityPoint,
    AccessibilityReadTarget,
    IdbException,
)
from idb.grpc.idb_pb2 import AccessibilityInfoRequest


def accessibility_info_to_grpc(
    target: AccessibilityReadTarget | None,
    options: AccessibilityInfoOptions,
) -> AccessibilityInfoRequest:
    """The wire request for a read of `target` under `options`.

    Four targets and one option decide which elements come back: no target is
    the whole frontmost app, an application is that app's whole tree whether
    frontmost or not, a point is the element under it, a marker is the single
    element that resolves, and `match` narrows a whole-app read to the elements
    whose `match_key` contains a substring.
    """
    if options.format is not None:
        wire_format = options.format.value
    elif options.nested:
        wire_format = AccessibilityInfoRequest.NESTED
    else:
        wire_format = AccessibilityInfoRequest.LEGACY
    request = AccessibilityInfoRequest(
        format=wire_format,
        keys=options.keys or [],
        profile=options.profile,
        collect_frame_coverage=options.collect_frame_coverage,
    )
    # Unset means "unspecified" on the wire: the companion's historical
    # default backend, and the only thing an older companion understands.
    if options.backend is not None:
        request.backend = options.backend.value
    if options.ignore_case:
        request.ignore_case = True
    if options.filter is not None:
        request.filter = options.filter.value
    # A match narrows the elements a whole-app read reports, so it is only
    # meaningful without a target. A marker read is the other verb — it selects
    # one element, and shares `match_key` with the match on the wire — and a
    # point read returns the one element under the point. Refusing here names
    # the caller's mistake rather than letting the companion's INVALID_ARGUMENT,
    # or a silently dropped field, do it.
    whole_app = target is None or isinstance(target, AccessibilityApplication)
    if options.display is not None and not isinstance(target, AccessibilityPoint):
        raise IdbException(
            "accessibility_info: a display says where a point is, so it needs a "
            "point target"
        )
    if options.match and not whole_app:
        raise IdbException(
            "accessibility_info: match narrows a whole-app read, so it "
            f"cannot be combined with a {type(target).__name__} target"
        )
    if isinstance(target, AccessibilityApplication):
        request.bundle_id = target.bundle_id
    if isinstance(target, AccessibilityMarker):
        request.marker = target.value
        request.match_key = target.match_key.value
        request.depth = target.depth
    elif isinstance(target, AccessibilityPoint):
        request.point.x = target.x
        request.point.y = target.y
        if options.display is not None:
            # An empty unique id selects the active display, so presence has
            # to be marked explicitly rather than implied by a non-default value.
            request.display.SetInParent()
            request.display.unique_id = (
                "" if options.display == ACTIVE_DISPLAY else options.display
            )
    elif options.match:
        request.match = options.match
        request.match_key = options.match_key.value
    return request
