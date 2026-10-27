#!/bin/sh
set -eu

cd "$(dirname "$0")/../.."
swift build --product val --skip-update --disable-automatic-resolution
VAELEN_VAL_EXECUTABLE="$PWD/.build/debug/val" Scripts/test.sh --filter ProjectRouteLifecycleEndToEndTests
