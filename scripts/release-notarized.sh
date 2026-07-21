#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
identity="Developer ID Application: Scott Phillips (RX977V4JGZ)"
team_id="RX977V4JGZ"
notary_profile=${NOTARY_PROFILE:-MessageVaultNotary}
skip_notarization=false
[[ ${1:-} == "--skip-notarization" ]] && skip_notarization=true

release_root=$(mktemp -d /tmp/messagevault-release.XXXXXX)
trap 'rm -rf "$release_root"' EXIT
derived_data="$release_root/DerivedData"
signed_app="$release_root/MessageVault.app"
submission_zip="$release_root/MessageVault-submission.zip"
final_zip="$release_root/MessageVault-macOS.zip"
entitlements="$project_root/Sources/MessageVault/MessageVault.entitlements"
output_zip="$project_root/outputs/MessageVault-macOS.zip"
archive_dir="$project_root/work/previous-output"

xcodebuild \
  -project "$project_root/MessageVault.xcodeproj" \
  -scheme MessageVault \
  -configuration Release \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  build

COPYFILE_DISABLE=1 /usr/bin/ditto "$derived_data/Build/Products/Release/MessageVault.app" "$signed_app"
/usr/bin/xattr -cr "$signed_app"
/usr/bin/codesign --force --deep --timestamp --options runtime --sign "$identity" --entitlements "$entitlements" "$signed_app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$signed_app"

(
  cd "$release_root"
  COPYFILE_DISABLE=1 /usr/bin/zip -qry -X "${submission_zip:t}" "${signed_app:t}"
)

if ! $skip_notarization; then
  /usr/bin/xcrun notarytool submit "$submission_zip" --keychain-profile "$notary_profile" --wait
  /usr/bin/xcrun stapler staple "$signed_app"
  /usr/bin/xcrun stapler validate "$signed_app"
fi

(
  cd "$release_root"
  COPYFILE_DISABLE=1 /usr/bin/zip -qry -X "${final_zip:t}" "${signed_app:t}"
)

mkdir -p "$project_root/outputs" "$archive_dir"
if [[ -e "$output_zip" ]]; then
  mv "$output_zip" "$archive_dir/MessageVault-$(date +%Y%m%d-%H%M%S).zip"
fi
mv "$final_zip" "$output_zip"

echo "Developer ID team: $team_id"
if $skip_notarization; then
  echo "Notarized: no"
else
  echo "Notarized: yes"
fi
echo "Release: $output_zip"
