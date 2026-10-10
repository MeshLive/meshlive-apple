#!/bin/bash
# Experimental standalone v1 (Noise XX) only; the Android-compatible protocol is checked by swift test (AndroidVectorTests).
set -euo pipefail
cd "$(dirname "$0")/.."
export JAVA_HOME="${JAVA_HOME:-$(pwd)/.build/android-tools/jdk/Contents/Home}"
bash Scripts/setup-interop.sh
mkdir -p .build/interop/classes
classpath='.build/interop/lib/*:.build/interop/classes'
# macOS Bash 3.2: use find's NUL-safe argument handling instead of mapfile.
find Interop/java -name '*.java' -print0 | xargs -0 "$JAVA_HOME/bin/javac" --release 11 -cp "$classpath" -d .build/interop/classes
"$JAVA_HOME/bin/java" -cp "$classpath" org.junit.runner.JUnitCore org.nearbyintercom.core.InteropTests
xcrun swiftc -swift-version 5 -parse-as-library Sources/NearbyCore/Binary.swift Sources/NearbyCore/Flow.swift Sources/NearbyCore/BoundedMailbox.swift Sources/NearbyV1Experimental/*.swift Scripts/InteropPeer.swift -o .build/interop/swift-peer
python3 Scripts/interop-check.py
