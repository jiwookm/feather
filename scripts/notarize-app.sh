#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
project_root=${script_directory:h}
application_path="$project_root/dist/Feather.app"
notary_profile=${FEATHER_NOTARY_PROFILE:-}
notary_key_path=${FEATHER_NOTARY_KEY_PATH:-}
notary_key_id=${FEATHER_NOTARY_KEY_ID:-}
notary_issuer_id=${FEATHER_NOTARY_ISSUER_ID:-}

if [[ -z "$notary_profile" \
    && ( -z "$notary_key_path" || -z "$notary_key_id" || -z "$notary_issuer_id" ) ]]; then
    print -u2 "Set FEATHER_NOTARY_PROFILE or all FEATHER_NOTARY_KEY_* variables."
    exit 2
fi
if [[ -n "$notary_profile" \
    && ( -n "$notary_key_path" || -n "$notary_key_id" || -n "$notary_issuer_id" ) ]]; then
    print -u2 "Choose a keychain profile or an App Store Connect API key, not both."
    exit 2
fi

if [[ ! -d "$application_path" ]]; then
    print -u2 "Missing $application_path. Build it with a Developer ID identity first."
    exit 2
fi

if ! /usr/bin/codesign -dv --verbose=4 "$application_path" 2>&1 \
    | /usr/bin/grep -q "Authority=Developer ID Application"; then
    print -u2 "Feather.app is not signed with a Developer ID Application certificate."
    exit 2
fi

temporary_directory=$(/usr/bin/mktemp -d -t feather-notarize)
archive_path="$temporary_directory/Feather.zip"
function cleanup {
    /bin/rm -rf -- "$temporary_directory"
}
trap cleanup EXIT

/usr/bin/ditto -c -k --keepParent "$application_path" "$archive_path"
if [[ -n "$notary_profile" ]]; then
    /usr/bin/xcrun notarytool submit \
        "$archive_path" \
        --keychain-profile "$notary_profile" \
        --wait
else
    /usr/bin/xcrun notarytool submit \
        "$archive_path" \
        --key "$notary_key_path" \
        --key-id "$notary_key_id" \
        --issuer "$notary_issuer_id" \
        --wait
fi
/usr/bin/xcrun stapler staple "$application_path"
/usr/bin/xcrun stapler validate "$application_path"
/usr/sbin/spctl --assess --type execute --verbose=2 "$application_path"
print "Notarized and stapled $application_path"
