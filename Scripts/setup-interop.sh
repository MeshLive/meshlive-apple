#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/interop/lib
fetch() {
    local url="$1" output="$2" sha="$3"
    if [[ ! -f "$output" ]]; then curl -fL --retry 2 --max-time 600 "$url" -o "$output"; fi
    [[ "$(shasum -a 256 "$output" | awk '{print $1}')" == "$sha" ]] || { echo "Checksum mismatch: $output" >&2; exit 1; }
}
if [[ -n "${JAVA_HOME:-}" ]] && [[ -x "$JAVA_HOME/bin/javac" ]]; then
    echo 'Using JAVA_HOME for the Java reference tests (JDK 17+).'
else
    [[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'Set JAVA_HOME to JDK 17+ on this platform.' >&2; exit 1; }
    # Reuse the task-local JDK if available; never replace a system installation.
    mkdir -p .build/android-tools
    fetch 'https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.20.1%2B1/OpenJDK17U-jdk_aarch64_mac_hotspot_17.0.20.1_1.tar.gz' .build/android-tools/jdk.tar.gz 196d13ba5f10414bef7f6a05a9b3f00edacb18ebacef2b99485db9e2ee18f0e8
    if [[ ! -d .build/android-tools/jdk ]]; then mkdir .build/android-tools/jdk; tar -xzf .build/android-tools/jdk.tar.gz -C .build/android-tools/jdk --strip-components=1; fi
fi
fetch 'https://repo.maven.apache.org/maven2/org/bouncycastle/bcprov-jdk18on/1.86/bcprov-jdk18on-1.86.jar' .build/interop/lib/bcprov.jar 2af190b300cbb0b35e248ccf5f4a06b6072030aeb3da7a98ec73abe5b4cb371f
fetch 'https://repo.maven.apache.org/maven2/junit/junit/4.13.2/junit-4.13.2.jar' .build/interop/lib/junit.jar 8e495b634469d64fb8acfa3495a065cbacc8a0fff55ce1e31007be4c16dc57d3
fetch 'https://repo.maven.apache.org/maven2/org/hamcrest/hamcrest-core/1.3/hamcrest-core-1.3.jar' .build/interop/lib/hamcrest.jar 66fdef91e9739348df7a096aa384a5685f4e875584cce89386a7a47251c4d8e9
fetch 'https://repo.maven.apache.org/maven2/org/json/json/20250517/json-20250517.jar' .build/interop/lib/json.jar 3ea61b2a06e31edf1c91134fe9106b0ebb16628be169f3db75bc7a2b06b45796
echo 'Interoperability test dependencies ready. No Android application is installed by this script.'
