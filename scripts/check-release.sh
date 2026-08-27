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
sparkle_framework="$project_root/dist/Feather.app/Contents/Frameworks/Sparkle.framework"
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
if [[ ! -d "$sparkle_framework" ]]; then
    print -u2 "Release build is missing Sparkle.framework."
    exit 1
fi
/usr/bin/codesign --verify --strict --verbose=2 "$sparkle_framework"
if ! /usr/bin/otool -L "$binary" | /usr/bin/grep -q '@rpath/Sparkle.framework'; then
    print -u2 "Release binary is not linked to its bundled Sparkle framework."
    exit 1
fi
if ! /usr/bin/otool -l "$binary" \
  | /usr/bin/grep -q '@executable_path/../Frameworks'; then
    print -u2 "Release binary cannot resolve its bundled Sparkle framework."
    exit 1
fi
feed_url=$(/usr/libexec/PlistBuddy \
    -c "Print :SUFeedURL" \
    "$project_root/dist/Feather.app/Contents/Info.plist")
public_update_key=$(/usr/libexec/PlistBuddy \
    -c "Print :SUPublicEDKey" \
    "$project_root/dist/Feather.app/Contents/Info.plist")
if [[ "$feed_url" != "https://github.com/jiwookm/feather/releases/download/updater-feed/appcast.xml" \
  || -z "$public_update_key" ]]; then
    print -u2 "Release build has incomplete updater trust configuration."
    exit 1
fi

bundle_kib=$(/usr/bin/du -sk "$project_root/dist/Feather.app" | /usr/bin/awk '{print $1}')
print "Release checks passed"
print "bundle_kib=$bundle_kib"
print "binary=${architecture#*: }"
