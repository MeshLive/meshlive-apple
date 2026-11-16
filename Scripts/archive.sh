#!/bin/bash
# Archive and export MeshLive for the App Store. It uploads no build; the export can contact App Store Connect for signing.
#
#   Scripts/archive.sh ios|mac [BUILD] [--out DIR] [--dry-run]
#
# Required environment (read here, never printed, never written to a file):
#   MESHLIVE_BUILD  optional when BUILD is given; the integer build number (CFBundleVersion). It must be greater than
#                   the project's current build number; there is no default, so a duplicate cannot happen silently.
#                   Every TestFlight upload needs a new value.
#   MESHLIVE_TEAM   the Apple developer team the owner selects.
# Optional, all three together (an App Store Connect API key for -allowProvisioningUpdates over SSH, where the login
# keychain is locked): ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID.
#
# The archive is checked with Scripts/release-check.sh (--store --archive), copied to an export options file with the
# team ID added, and exported locally. Nothing is uploaded by this script.
#
# mac mode is UNVERIFIED: the native Mac app is submitted after the iPhone, and its automatic distribution signing
# overrides have not been run.
set +x
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
    echo "usage: $0 ios|mac [BUILD] [--out DIR] [--dry-run]" >&2
    exit 2
}

platform="${1:-}"
[ -n "$platform" ] || usage
shift
build_arg=""
if [ "$#" -gt 0 ] && [[ "$1" =~ ^[0-9]+$ ]]; then
    build_arg="$1"
    shift
fi
out=""
dry_run=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --out) [ "$#" -ge 2 ] || usage; out="$2"; shift 2 ;;
        --dry-run) dry_run=1; shift ;;
        *) usage ;;
    esac
done
case "$platform" in
    ios|mac) ;;
    *) usage ;;
esac

build="${build_arg:-${MESHLIVE_BUILD:-}}"
if [ -n "$build_arg" ] && [ -n "${MESHLIVE_BUILD:-}" ] && [ "$build_arg" != "$MESHLIVE_BUILD" ]; then
    echo "The positional build number and MESHLIVE_BUILD disagree; pass one or the same value." >&2
    exit 2
fi
MESHLIVE_BUILD="$build"
if [ -z "$MESHLIVE_BUILD" ]; then
    echo "A build number is required (pass it after ios|mac or set MESHLIVE_BUILD)." >&2
    exit 2
fi
if ! [[ "$MESHLIVE_BUILD" =~ ^[0-9]+$ ]]; then
    echo "The build number must be an integer." >&2
    exit 2
fi
project_build="$(sed -n 's/.*CURRENT_PROJECT_VERSION = "\([0-9][0-9]*\)".*/\1/p' MeshLive.xcodeproj/project.pbxproj 2>/dev/null | sort -n | tail -1 || true)"
if [ -z "$project_build" ]; then
    echo "Could not read CURRENT_PROJECT_VERSION from MeshLive.xcodeproj/project.pbxproj." >&2
    exit 1
fi
if [ "$((10#$MESHLIVE_BUILD))" -le "$((10#$project_build))" ]; then
    echo "The build number ($MESHLIVE_BUILD) must be greater than the project's current build number ($project_build)." >&2
    exit 2
fi
if [ -z "${MESHLIVE_TEAM:-}" ]; then
    echo "MESHLIVE_TEAM is required (the Apple developer team)." >&2
    exit 2
fi
asc_count=0
for variable in ASC_KEY_PATH ASC_KEY_ID ASC_ISSUER_ID; do
    [ -z "${!variable:-}" ] || asc_count=$((asc_count + 1))
done
if [ "$asc_count" -ne 0 ] && [ "$asc_count" -ne 3 ]; then
    echo "ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID must be set together or not at all." >&2
    exit 2
fi

# 1. Pre-checks: a store build comes from a clean, committed tree.
if [ -n "$(git status --porcelain)" ]; then
    echo "The working tree is not clean; commit or restore everything before archiving." >&2
    exit 1
fi
if [ "$platform" = mac ]; then
    for framework in Vendor/Opus.xcframework Vendor/VPX-macos.xcframework; do
        if [ ! -d "$framework" ]; then
            echo "Missing $framework; run the preparation scripts first." >&2
            exit 1
        fi
    done
else
    for framework in Vendor/Opus.xcframework Vendor/VPX.xcframework; do
        if [ ! -d "$framework" ]; then
            echo "Missing $framework; run the preparation scripts first." >&2
            exit 1
        fi
    done
fi
if ! python3 Scripts/project.py >/dev/null; then
    echo "Scripts/project.py failed." >&2
    exit 1
fi
if ! git diff --quiet MeshLive.xcodeproj; then
    echo "MeshLive.xcodeproj changed when regenerated; commit the regenerated project first." >&2
    exit 1
fi

commit="$(git rev-parse --short=7 HEAD)"
if [ -z "$out" ]; then
    out=".build/store/$commit-$MESHLIVE_BUILD"
fi

auth=()
if [ "$asc_count" -eq 3 ]; then
    auth=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

if [ "$platform" = ios ]; then
    archive="$out/MeshLive-iOS.xcarchive"
    archive_cmd=(xcodebuild archive -project MeshLive.xcodeproj -scheme MeshLive-iOS -configuration Release
        -destination "generic/platform=iOS" -archivePath "$archive" -allowProvisioningUpdates
        ${auth[@]+"${auth[@]}"}
        DEVELOPMENT_TEAM="$MESHLIVE_TEAM" CODE_SIGN_STYLE=Automatic
        CURRENT_PROJECT_VERSION="$MESHLIVE_BUILD" MESHLIVE_SOURCE_COMMIT="$commit" MESHLIVE_DISTRIBUTION=appstore)
else
    archive="$out/MeshLive-mac.xcarchive"
    archive_cmd=(xcodebuild archive -project MeshLive.xcodeproj -scheme MeshLive -configuration Release
        -destination "generic/platform=macOS" -archivePath "$archive" -allowProvisioningUpdates
        ${auth[@]+"${auth[@]}"}
        DEVELOPMENT_TEAM="$MESHLIVE_TEAM" CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Distribution"
        CURRENT_PROJECT_VERSION="$MESHLIVE_BUILD" MESHLIVE_SOURCE_COMMIT="$commit" MESHLIVE_DISTRIBUTION=appstore)
fi
app="$archive/Products/Applications/MeshLive.app"
export_dir="$out/export-$platform"
export_cmd=(xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$out/ExportOptions.plist"
    -exportPath "$export_dir" -allowProvisioningUpdates ${auth[@]+"${auth[@]}"})

print_command() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            DEVELOPMENT_TEAM=*) printf 'DEVELOPMENT_TEAM=<redacted> ' ;;
            *)
                if [ -n "${MESHLIVE_TEAM:-}" ] && [ "$arg" = "$MESHLIVE_TEAM" ]; then
                    printf '<redacted> '
                elif [ -n "${ASC_KEY_PATH:-}" ] && [ "$arg" = "$ASC_KEY_PATH" ]; then
                    printf '<redacted> '
                elif [ -n "${ASC_KEY_ID:-}" ] && [ "$arg" = "$ASC_KEY_ID" ]; then
                    printf '<redacted> '
                elif [ -n "${ASC_ISSUER_ID:-}" ] && [ "$arg" = "$ASC_ISSUER_ID" ]; then
                    printf '<redacted> '
                else
                    printf '%q ' "$arg"
                fi
                ;;
        esac
    done
    echo
}

if [ "$dry_run" -eq 1 ]; then
    echo "Pre-checks passed (dry run; nothing was built, signed, exported or uploaded)."
    echo "Archive:"
    print_command "${archive_cmd[@]}"
    echo "Release check:"
    print_command bash Scripts/release-check.sh "$app" --store --archive "$archive"
    echo "Export options:"
    printf 'cp store/ExportOptions-%s.plist %q\n' "$platform" "$out/ExportOptions.plist"
    echo "/usr/libexec/PlistBuddy -c \"Add :teamID string <redacted>\" \"$out/ExportOptions.plist\""
    echo "Export:"
    print_command "${export_cmd[@]}"
    exit 0
fi

mkdir -p "$out"
"${archive_cmd[@]}"
bash Scripts/release-check.sh "$app" --store --archive "$archive"

cp "store/ExportOptions-$platform.plist" "$out/ExportOptions.plist"
/usr/libexec/PlistBuddy -c "Add :teamID string $MESHLIVE_TEAM" "$out/ExportOptions.plist"
rm -rf "$export_dir"
"${export_cmd[@]}"

artifact=""
for candidate in "$export_dir"/*.ipa "$export_dir"/*.pkg; do
    if [ -e "$candidate" ]; then
        artifact="$candidate"
        break
    fi
done
if [ -z "$artifact" ]; then
    echo "No .ipa or .pkg was produced in $export_dir." >&2
    exit 1
fi
plist="$app/Info.plist"
[ -f "$plist" ] || plist="$app/Contents/Info.plist"
version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist")"
build="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist")"
sha="$(shasum -a 256 "$artifact" | awk '{print $1}')"
echo "Archive: $archive"
echo "Export: $artifact"
echo "Version: $version (build $build)"
echo "Commit: $commit"
echo "SHA-256: $sha"
echo "Archive and export finished. Nothing was uploaded; uploading is a separate manual step by the owner."
