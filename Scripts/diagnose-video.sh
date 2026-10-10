#!/bin/bash
# Experimental standalone v1 (Noise XX) only; the Android-compatible protocol is checked by swift test (AndroidVectorTests).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/diagnostics
xcrun swiftc -swift-version 5 -parse-as-library -emit-library -emit-module -module-name NearbyCore Sources/NearbyCore/Binary.swift Sources/NearbyCore/Flow.swift Sources/NearbyCore/BoundedMailbox.swift Sources/NearbyV1Experimental/*.swift -o .build/diagnostics/libNearbyCore.dylib -emit-module-path .build/diagnostics/NearbyCore.swiftmodule
xcrun swiftc -swift-version 5 -parse-as-library -I .build/diagnostics -L .build/diagnostics -lNearbyCore -Xlinker -rpath -Xlinker "$(pwd)/.build/diagnostics" Experimental/V1App/Media/PatternVideo.swift Scripts/CodecDiagnostic.swift -o .build/diagnostics/codec-check
.build/diagnostics/codec-check
