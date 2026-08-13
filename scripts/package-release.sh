#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
project_root=${script_directory:h}
application_path="$project_root/dist/Feather.app"
release_version=${FEATHER_RELEASE_VERSION:-}
distribution_mode=${FEATHER_DISTRIBUTION_MODE:-signed}

if [[ ! -d "$application_path" ]]; then
    print -u2 "Missing $application_path. Build Feather before packaging a release."
    exit 2
fi
if [[ ! "$release_version" =~ '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$' ]]; then
    print -u2 "Set FEATHER_RELEASE_VERSION to a semantic version such as 0.1.0."
    exit 2
fi
if [[ "$distribution_mode" != "signed" && "$distribution_mode" != "unsigned" ]]; then
    print -u2 "FEATHER_DISTRIBUTION_MODE must be signed or unsigned."
    exit 2
fi
if [[ "$distribution_mode" == "signed" ]]; then
    if ! /usr/bin/codesign -dv --verbose=4 "$application_path" 2>&1 \
        | /usr/bin/grep -q "Authority=Developer ID Application"; then
        print -u2 "Signed releases require a Developer ID Application signature."
        exit 2
    fi
    /usr/bin/xcrun stapler validate "$application_path"
fi

bundle_version=$(/usr/libexec/PlistBuddy \
    -c "Print :CFBundleShortVersionString" \
    "$application_path/Contents/Info.plist")
if [[ "$bundle_version" != "$release_version" ]]; then
    print -u2 "Bundle version $bundle_version does not match release $release_version."
    exit 2
fi

suffix=
if [[ "$distribution_mode" == "unsigned" ]]; then
    suffix="-unsigned"
fi
archive_name="Feather-$release_version-arm64$suffix"
output_directory="$project_root/dist/releases"
disk_image_path="$output_directory/$archive_name.dmg"
checksum_path="$disk_image_path.sha256"
temporary_directory=$(/usr/bin/mktemp -d -t feather-release)

function cleanup {
    /bin/rm -rf -- "$temporary_directory"
}
trap cleanup EXIT

/bin/mkdir -p "$output_directory" "$temporary_directory/image"
/bin/rm -f -- "$disk_image_path" "$checksum_path"
/usr/bin/ditto "$application_path" "$temporary_directory/image/Feather.app"
/bin/ln -s /Applications "$temporary_directory/image/Applications"
/usr/bin/hdiutil create \
    -volname "Feather $release_version" \
    -srcfolder "$temporary_directory/image" \
    -ov \
    -format UDZO \
    "$disk_image_path"

(
    cd "$output_directory"
    /usr/bin/shasum -a 256 "${disk_image_path:t}" > "${checksum_path:t}"
)

print "Packaged $disk_image_path"
print "Checksum $checksum_path"
