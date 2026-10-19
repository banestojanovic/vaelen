#!/bin/sh
set -eu

cd "$(dirname "$0")/../.."
swift build --product val
VAELEN_VAL_EXECUTABLE="$PWD/.build/debug/val" swift test --filter LogsIPCIntegrationTests
