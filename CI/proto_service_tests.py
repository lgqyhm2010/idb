#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

"""Cheap entrypoint-name checks; native CI still verifies generated signatures."""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def missing_rpc_entrypoints(proto: str, provider: str) -> set[str]:
    # grpc-swift-2 preserves the RPC spelling, including underscores. A camel-
    # cased method is a different Swift member and cannot satisfy the protocol.
    rpcs = set(re.findall(r"^\s*rpc\s+(\w+)\s*\(", proto, re.MULTILINE))
    methods = set(re.findall(r"^\s*func\s+(\w+)\s*\(", provider, re.MULTILINE))
    return rpcs - methods


class CompanionRPCEntrypointTests(unittest.TestCase):
    def test_provider_implements_every_proto_rpc_name(self) -> None:
        proto = (ROOT / "proto/idb.proto").read_text()
        provider = (
            ROOT / "CompanionLib/SwiftServer/CompanionServiceProvider.swift"
        ).read_text()
        self.assertIn("rpc list_displays(", proto)
        self.assertEqual(missing_rpc_entrypoints(proto, provider), set())

    def test_new_display_rpc_matches_generated_unary_signature(self) -> None:
        # Actual generated SimpleServiceProtocol requirement, verified from
        # grpc-swift-protobuf 2.4.1 (Package.resolved revision 176c5a434fd7),
        # idb.grpc.swift:2651 in CI run 37303494671's raw xcodebuild log.
        # A source guard supplements, never replaces, native type checking.
        provider = (
            ROOT / "CompanionLib/SwiftServer/CompanionServiceProvider.swift"
        ).read_text()
        self.assertRegex(
            provider,
            r"func list_displays\(\s*request: Idb_ListDisplaysRequest,\s*"
            r"context: ServerContext\s*\) async throws -> Idb_ListDisplaysResponse\s*\{",
        )

    def test_camel_casing_does_not_satisfy_a_snake_case_rpc(self) -> None:
        self.assertEqual(
            missing_rpc_entrypoints(
                "  rpc list_displays(Request) returns (Response) {}",
                "  func listDisplays(request: Request) async throws -> Response {}",
            ),
            {"list_displays"},
        )

    def test_exact_name_satisfies_the_entrypoint_check(self) -> None:
        self.assertEqual(
            missing_rpc_entrypoints(
                "  rpc list_displays(Request) returns (Response) {}",
                "  func list_displays(request: Request) async throws -> Response {}",
            ),
            set(),
        )
