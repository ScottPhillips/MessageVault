#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
release_app="$project_root/work/DerivedDataRelease/Build/Products/Release/MessageVault.app"
output_app="$project_root/outputs/MessageVault.app"
output_zip="$project_root/outputs/MessageVault-macOS.zip"
entitlements="$project_root/Sources/MessageVault/MessageVault.entitlements"
archive_dir="$project_root/work/previous-output"

mkdir -p "$project_root/outputs" "$archive_dir"
if [[ -e "$output_app" ]]; then
  mv "$output_app" "$archive_dir/MessageVault-$(date +%Y%m%d-%H%M%S).app"
fi
if [[ -e "$output_zip" ]]; then
  mv "$output_zip" "$archive_dir/MessageVault-$(date +%Y%m%d-%H%M%S).zip"
fi

COPYFILE_DISABLE=1 /usr/bin/ditto "$release_app" "$output_app"
/usr/bin/xattr -cr "$output_app"
/usr/bin/codesign --force --deep --sign - --options runtime --entitlements "$entitlements" "$output_app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$output_app"
(
  cd "$project_root/outputs"
  COPYFILE_DISABLE=1 /usr/bin/zip -qry -X "${output_zip:t}" "${output_app:t}"
)

echo "Packaged $output_zip"
