#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
(cd "$repo_root" && swift build --product val)
exec "$repo_root/.build/debug/val" shell install
