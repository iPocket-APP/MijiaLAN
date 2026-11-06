#!/usr/bin/env bash
set -euo pipefail
EXPERIMENT_ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$EXPERIMENT_ROOT/../.." && pwd)"
cd "$EXPERIMENT_ROOT"
python3 prepare.py
xcodegen generate --spec project.yml
mkdir -p MijiaLANTVPrototype.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp Package.resolved MijiaLANTVPrototype.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
BUILD_MODE="${1:-simulator}"
if [[ "$BUILD_MODE" == ios-* ]]; then
    BUILD_ARGS=(-project MijiaLANTVPrototype.xcodeproj -scheme MijiaLANiOSPrototype
        -derivedDataPath "$REPO_ROOT/build/ios-prototype-derived")
else
    BUILD_ARGS=(-project MijiaLANTVPrototype.xcodeproj -scheme MijiaLANTVPrototype
        -derivedDataPath "$REPO_ROOT/build/tvos-prototype-derived")
fi
BUILD_ARGS+=(-onlyUsePackageVersionsFromResolvedFile)
case "$BUILD_MODE" in
    simulator)
        xcodebuild "${BUILD_ARGS[@]}" -configuration Debug -destination 'generic/platform=tvOS Simulator' \
            CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build
        ;;
    device)
        : "${MIJIALAN_TV_TEAM:?Set MIJIALAN_TV_TEAM to your Apple Developer team ID}"
        xcodebuild "${BUILD_ARGS[@]}" -configuration Release -destination 'generic/platform=tvOS' \
            -archivePath "$REPO_ROOT/build/MijiaLANTVPrototype.xcarchive" -allowProvisioningUpdates \
            DEVELOPMENT_TEAM="$MIJIALAN_TV_TEAM" archive
        ;;
    unsigned-archive)
        xcodebuild "${BUILD_ARGS[@]}" -configuration Release -destination 'generic/platform=tvOS' \
            -archivePath "$REPO_ROOT/build/MijiaLANTVPrototype-unsigned.xcarchive" \
            CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO archive
        ;;
    ios-simulator)
        xcodebuild "${BUILD_ARGS[@]}" -configuration Debug -destination 'generic/platform=iOS Simulator' \
            CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build
        ;;
    ios-device)
        : "${MIJIALAN_IOS_TEAM:?Set MIJIALAN_IOS_TEAM to your Apple Developer team ID}"
        xcodebuild "${BUILD_ARGS[@]}" -configuration Debug -destination 'generic/platform=iOS' \
            -allowProvisioningUpdates DEVELOPMENT_TEAM="$MIJIALAN_IOS_TEAM" build
        ;;
    ios-archive)
        : "${MIJIALAN_IOS_TEAM:?Set MIJIALAN_IOS_TEAM to your Apple Developer team ID}"
        xcodebuild "${BUILD_ARGS[@]}" -configuration Release -destination 'generic/platform=iOS' \
            -archivePath "$REPO_ROOT/build/MijiaLANiOSPrototype.xcarchive" -allowProvisioningUpdates \
            DEVELOPMENT_TEAM="$MIJIALAN_IOS_TEAM" archive
        ;;
    *) printf 'Usage: %s [simulator|device|unsigned-archive|ios-simulator|ios-device|ios-archive]\n' "$0" >&2; exit 2 ;;
esac
