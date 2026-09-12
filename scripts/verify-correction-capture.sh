#!/bin/bash
set -euo pipefail

# Run on an unlocked Mac; the Xcode test host needs Accessibility permission.
# Only the disposable fixture is edited. No real documents or clipboard are used.
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
fixture_root="$(mktemp -d -t mouthpiece-correction)"
fixture_app="$fixture_root/MouthpieceCorrectionFixture.app"
mkdir -p "$fixture_app/Contents/MacOS"
fixture_plist="$fixture_app/Contents/Info.plist"
plutil -create xml1 "$fixture_plist"
plutil -insert CFBundleIdentifier -string com.mouthpiece.correction-fixture "$fixture_plist"
plutil -insert CFBundleExecutable -string MouthpieceCorrectionFixture "$fixture_plist"
plutil -insert CFBundleName -string MouthpieceCorrectionFixture "$fixture_plist"
plutil -insert CFBundlePackageType -string APPL "$fixture_plist"
swiftc scripts/correction-capture-fixture.swift -o "$fixture_app/Contents/MacOS/MouthpieceCorrectionFixture"
"$fixture_app/Contents/MacOS/MouthpieceCorrectionFixture" &
fixture_pid=$!
trap 'kill "$fixture_pid" 2>/dev/null || true' EXIT
xcodegen generate
xcodebuild -project Mouthpiece.xcodeproj -scheme Mouthpiece -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build/xcode \
  -clonedSourcePackagesDirPath .build/spm-packages \
  -resultBundlePath "$fixture_root/Capture.xcresult" \
  -only-testing:MouthpieceTests/CorrectionCaptureLiveTests test CODE_SIGNING_ALLOWED=NO
xcrun xcresulttool get test-results summary --path "$fixture_root/Capture.xcresult"
printf 'Fixture and result bundle retained at %s\n' "$fixture_root"
