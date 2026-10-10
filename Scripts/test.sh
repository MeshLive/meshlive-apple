#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift test --scratch-path .build/swift --disable-sandbox "$@"
