#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

from unittest.mock import AsyncMock, MagicMock

from idb.common.hid import pinch_to_events, swipe_to_events, tap_to_events
from idb.common.types import DisplayInfo, HIDDisplay
from idb.grpc.client import Client
from idb.grpc.idb_pb2 import ListDisplaysRequest, ListDisplaysResponse
from idb.utils.testing import TestCase


class DisplayTests(TestCase):
    def setUp(self) -> None:
        super().setUp()
        self.client = Client.__new__(Client)
        self.client.logger = MagicMock()
        self.client.stub = MagicMock()
        self.client.send_events = AsyncMock()

    async def test_touches_without_a_display_are_unchanged(self) -> None:
        await self.client.tap(10, 20)
        self.client.send_events.assert_awaited_once_with(tap_to_events(10, 20))

    async def test_a_display_selection_leads_the_touches(self) -> None:
        await self.client.tap(10, 20, display="inner")
        self.client.send_events.assert_awaited_once_with(
            [HIDDisplay(unique_id="inner"), *tap_to_events(10, 20)]
        )

    async def test_active_selects_the_lit_display(self) -> None:
        await self.client.swipe((1, 2), (3, 4), display="active")
        self.client.send_events.assert_awaited_once_with(
            [HIDDisplay(unique_id=""), *swipe_to_events((1, 2), (3, 4), None, None)]
        )

    async def test_pinch_routes_both_fingers(self) -> None:
        await self.client.pinch(200, 400, 2.0, display="inner")
        self.client.send_events.assert_awaited_once_with(
            [
                HIDDisplay(unique_id="inner"),
                *pinch_to_events(
                    center_x=200, center_y=400, scale=2.0, duration=0.5, radius=100.0
                ),
            ]
        )

    async def test_list_displays(self) -> None:
        self.client.stub.list_displays = AsyncMock(
            return_value=ListDisplaysResponse(
                displays=[
                    ListDisplaysResponse.Display(
                        unique_id="inner",
                        name="Inner",
                        active=True,
                        integrated=True,
                        width=2007,
                        height=2853,
                        scale=3,
                        rotation="rot0",
                        touchscreen=True,
                    ),
                    ListDisplaysResponse.Display(
                        unique_id="cover",
                        name="Cover",
                        primary=True,
                        integrated=True,
                        width=1398,
                        height=2034,
                        scale=3,
                        rotation="rot0",
                        touchscreen=True,
                    ),
                ]
            )
        )
        self.assertEqual(
            await self.client.list_displays(),
            [
                DisplayInfo(
                    unique_id="inner",
                    name="Inner",
                    active=True,
                    primary=False,
                    integrated=True,
                    width=2007,
                    height=2853,
                    scale=3,
                    rotation="rot0",
                    touchscreen=True,
                ),
                DisplayInfo(
                    unique_id="cover",
                    name="Cover",
                    active=False,
                    primary=True,
                    integrated=True,
                    width=1398,
                    height=2034,
                    scale=3,
                    rotation="rot0",
                    touchscreen=True,
                ),
            ],
        )
        self.client.stub.list_displays.assert_awaited_once_with(ListDisplaysRequest())
