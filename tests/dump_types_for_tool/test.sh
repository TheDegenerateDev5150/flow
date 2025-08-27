#!/bin/bash
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

assert_ok "$FLOW" dump-types --for-tool --strip-root --json --pretty test.js
assert_ok "$FLOW" dump-types --for-tool 0 --strip-root --json --pretty test.js
