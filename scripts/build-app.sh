#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
project_root=${script_directory:h}
signing_identity=${FEATHER_SIGN_IDENTITY:--}
release_version=${FEATHER_RELEASE_VERSION:-}
build_number=${FEATHER_BUILD_NUMBER:-}
build_variant=${FEATHER_BUILD_VARIANT:-development}

case "$build_variant" in
  development)
    application_name="Feather Dev"
    bundle_identifier="com.jiwookim.feather.dev"
    ;;
  production)
    application_name="Feather"
    bundle_identifier="com.jiwookim.feather"
    ;;
  *)
    print -u2 "FEATHER_BUILD_VARIANT must be development or production."
    exit 1
    ;;
esac

application_path="$project_root/dist/$application_name.app"

if [[ "$application_path" != "$project_root/dist/Feather.app" \
  && "$application_path" != "$project_root/dist/Feather Dev.app" ]]; then
    print -u2 "Refusing to package an unexpected path: $application_path"
    exit 1
fi

if [[ -n "$release_version" && ! "$release_version" =~ '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$' ]]; then
    print -u2 "Invalid FEATHER_RELEASE_VERSION: $release_version"
    exit 1
fi
if [[ -n "$build_number" && ! "$build_number" =~ '^[1-9][0-9]*$' ]]; then
    print -u2 "Invalid FEATHER_BUILD_NUMBER: $build_number"
    exit 1
fi

cd "$project_root"
/usr/bin/swift build --configuration release --arch arm64
binary_directory=$(/usr/bin/swift build --configuration release --arch arm64 --show-bin-path)

/bin/rm -rf -- "$application_path"
/bin/mkdir -p \
    "$application_path/Contents/MacOS" \
    "$application_path/Contents/Resources/AgentIcons" \
    "$application_path/Contents/Resources/Fonts"
/bin/cp "$binary_directory/Feather" "$application_path/Contents/MacOS/Feather"
/bin/cp "$project_root/Resources/Info.plist" "$application_path/Contents/Info.plist"
/bin/cp "$project_root/Resources/Feather.icns" "$application_path/Contents/Resources/Feather.icns"
/bin/cp "$project_root/Resources/AgentIcons/Claude.svg" "$application_path/Contents/Resources/AgentIcons/Claude.svg"
/bin/cp "$project_root/Resources/AgentIcons/OpenAI.svg" "$application_path/Contents/Resources/AgentIcons/OpenAI.svg"
/bin/cp "$project_root/Resources/ThirdPartyNotices.txt" "$application_path/Contents/Resources/ThirdPartyNotices.txt"
/bin/cp "$project_root/Resources/Fonts/Geist.ttf" "$application_path/Contents/Resources/Fonts/Geist.ttf"
/bin/cp "$project_root/Resources/Fonts/Geist-LICENSE.txt" "$application_path/Contents/Resources/Fonts/Geist-LICENSE.txt"
/bin/chmod 755 "$application_path/Contents/MacOS/Feather"

/usr/libexec/PlistBuddy \
    -c "Set :CFBundleDisplayName $application_name" \
    -c "Set :CFBundleName $application_name" \
    -c "Set :CFBundleIdentifier $bundle_identifier" \
    -c "Set :FeatherBuildVariant $build_variant" \
    "$application_path/Contents/Info.plist"

if [[ -n "$release_version" ]]; then
    /usr/libexec/PlistBuddy \
        -c "Set :CFBundleShortVersionString $release_version" \
        "$application_path/Contents/Info.plist"
fi
if [[ -n "$build_number" ]]; then
    /usr/libexec/PlistBuddy \
        -c "Set :CFBundleVersion $build_number" \
        "$application_path/Contents/Info.plist"
fi

if [[ "$signing_identity" == "-" ]]; then
    /usr/bin/codesign --force --sign - --timestamp=none "$application_path"
else
    /usr/bin/codesign \
        --force \
        --options runtime \
        --timestamp \
        --sign "$signing_identity" \
        "$application_path"
fi
/usr/bin/codesign --verify --strict --verbose=2 "$application_path"
/usr/bin/plutil -lint "$application_path/Contents/Info.plist"
/usr/bin/file "$application_path/Contents/MacOS/Feather"
print "Built $application_path"
