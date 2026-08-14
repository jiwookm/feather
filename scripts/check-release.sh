#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
project_root=${script_directory:h}

cd "$project_root"

/bin/zsh -n \
    "$script_directory/build-app.sh" \
    "$script_directory/check-release.sh" \
    "$script_directory/notarize-app.sh" \
    "$script_directory/package-release.sh" \
    "$script_directory/performance-report.sh"
/usr/bin/swift format lint --recursive --strict Sources Tests Package.swift
/usr/bin/swift test --no-parallel
FEATHER_BUILD_VARIANT=production "$script_directory/build-app.sh"
/usr/bin/git diff --check

binary="$project_root/dist/Feather.app/Contents/MacOS/Feather"
bundle_identifier=$(/usr/libexec/PlistBuddy \
    -c "Print :CFBundleIdentifier" \
    "$project_root/dist/Feather.app/Contents/Info.plist")
build_variant=$(/usr/libexec/PlistBuddy \
    -c "Print :FeatherBuildVariant" \
    "$project_root/dist/Feather.app/Contents/Info.plist")
if [[ "$bundle_identifier" != "com.jiwookim.feather" || "$build_variant" != "production" ]]; then
    print -u2 "Release build has the wrong runtime identity."
    exit 1
fi
architecture=$(/usr/bin/file "$binary")
if [[ "$architecture" != *"arm64"* || "$architecture" == *"x86_64"* ]]; then
    print -u2 "Release binary is not arm64-only: $architecture"
    exit 1
fi

bundle_kib=$(/usr/bin/du -sk "$project_root/dist/Feather.app" | /usr/bin/awk '{print $1}')
print "Release checks passed"
print "bundle_kib=$bundle_kib"
print "binary=${architecture#*: }"
