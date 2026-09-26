#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

from unittest.mock import AsyncMock, MagicMock

from idb.common.hid import drag_to_events, from_edge, swipe_to_events
from idb.common.types import (
    HIDDelay,
    HIDDirection,
    HIDDisplay,
    HIDEdge,
    HIDEdgeType,
    HIDPress,
    HIDTouch,
    Point,
)
from idb.grpc.client import Client
from idb.grpc.hid import event_to_grpc
from idb.grpc.idb_pb2 import HIDEvent as GrpcHIDEvent
from idb.utils.testing import TestCase


class EdgeTests(TestCase):
    def setUp(self) -> None:
        super().setUp()
        self.client = Client.__new__(Client)
        self.client.logger = MagicMock()
        self.client.stub = MagicMock()
        self.client.send_events = AsyncMock()

    async def test_swipes_without_an_edge_are_unchanged(self) -> None:
        await self.client.swipe((1, 2), (3, 4))
        self.client.send_events.assert_awaited_once_with(
            swipe_to_events((1, 2), (3, 4), None, None)
        )

    async def test_an_edge_selection_leads_the_touches_after_the_display(
        self,
    ) -> None:
        await self.client.swipe(
            (100, 668), (100, 300), display="active", edge=HIDEdgeType.BOTTOM
        )
        self.client.send_events.assert_awaited_once_with(
            [
                HIDDisplay(unique_id=""),
                HIDEdge(edge=HIDEdgeType.BOTTOM),
                *swipe_to_events((100, 668), (100, 300), None, None),
            ]
        )

    def test_no_edge_sends_no_selection(self) -> None:
        events = swipe_to_events((1, 2), (3, 4))
        self.assertEqual(from_edge(None, events), events)
        self.assertEqual(from_edge(HIDEdgeType.NONE, events), events)

    def test_every_edge_reaches_the_wire(self) -> None:
        wire = {
            HIDEdgeType.NONE: GrpcHIDEvent.EDGE_NONE,
            HIDEdgeType.TOP: GrpcHIDEvent.EDGE_TOP,
            HIDEdgeType.LEFT: GrpcHIDEvent.EDGE_LEFT,
            HIDEdgeType.BOTTOM: GrpcHIDEvent.EDGE_BOTTOM,
            HIDEdgeType.RIGHT: GrpcHIDEvent.EDGE_RIGHT,
        }
        self.assertEqual(set(wire), set(HIDEdgeType))
        for edge, expected in wire.items():
            with self.subTest(edge=edge):
                self.assertEqual(event_to_grpc(HIDEdge(edge=edge)).edge.edge, expected)


class DragTests(TestCase):
    def _points(self, events: list) -> list[tuple[float, float]]:
        return [
            (event.action.point.x, event.action.point.y)
            for event in events
            if isinstance(event, HIDPress) and event.direction == HIDDirection.DOWN
        ]

    def test_the_path_turns_its_corners(self) -> None:
        events = drag_to_events([(0, 100), (0, 0), (100, 0)], duration=1.0, delta=50)
        self.assertEqual(
            self._points(events), [(0, 100), (0, 50), (0, 0), (50, 0), (100, 0)]
        )

    def test_one_contact_is_held_down_and_lifted_at_the_last_point(self) -> None:
        events = drag_to_events([(0, 0), (30, 40)], duration=0.5, delta=100)
        presses = [event for event in events if isinstance(event, HIDPress)]
        self.assertTrue(
            all(event.direction == HIDDirection.DOWN for event in presses[:-1])
        )
        self.assertEqual(
            presses[-1],
            HIDPress(action=HIDTouch(point=Point(x=30, y=40)), direction=HIDDirection.UP),
        )

    def test_the_duration_is_spread_over_the_samples(self) -> None:
        events = drag_to_events([(0, 0), (0, 100)], duration=2.0, delta=10)
        delays = [event.duration for event in events if isinstance(event, HIDDelay)]
        self.assertAlmostEqual(sum(delays), 2.0)

    def test_a_single_point_is_not_a_drag(self) -> None:
        with self.assertRaises(ValueError):
            drag_to_events([(0, 0)])

    async def test_the_client_tags_a_drag_with_its_edge(self) -> None:
        client = Client.__new__(Client)
        client.logger = MagicMock()
        client.send_events = AsyncMock()
        points = [(236.0, 668.0), (236.0, 600.0), (700.0, 330.0)]
        await client.drag(points, duration=2.0, edge=HIDEdgeType.BOTTOM)
        client.send_events.assert_awaited_once_with(
            [HIDEdge(edge=HIDEdgeType.BOTTOM), *drag_to_events(points, 2.0, None)]
        )
