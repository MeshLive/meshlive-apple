#!/bin/bash
# Experimental standalone v1 (Noise XX) only; the Android-compatible protocol is checked by swift test (AndroidVectorTests).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/fixtures Tests/NearbyV1ExperimentalTests/Fixtures
xcrun swiftc -swift-version 5 -parse-as-library Sources/NearbyCore/Binary.swift Sources/NearbyCore/Flow.swift Sources/NearbyCore/BoundedMailbox.swift Sources/NearbyV1Experimental/*.swift Scripts/Fixture.swift -o .build/fixtures/generate
.build/fixtures/generate > .build/fixtures/session-v1.json
if [[ "${1:-}" == --write ]]; then cp .build/fixtures/session-v1.json Tests/NearbyV1ExperimentalTests/Fixtures/session-v1.json; else diff -u Tests/NearbyV1ExperimentalTests/Fixtures/session-v1.json .build/fixtures/session-v1.json; fi
