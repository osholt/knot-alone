#!/usr/bin/env bash
# Build, sign, upload and publish an iOS build to the internal testers.
#
# Written because builds 22 and 23 were both assembled by hand from one
# session's shell history, and each one rediscovered the same traps. Every
# non-obvious step below is non-obvious for a reason recorded next to it.
#
#   tools/release/release.sh
#   tools/release/release.sh --dry-run     # everything up to the upload
#
# Requires: Xcode signed in to the Apple Developer account, and an App Store
# Connect API key of App Manager or better. A Developer-role key can neither
# upload nor do cloud signing.
set -euo pipefail

BUNDLE_ID="${TIDE_AND_SEEK_BUNDLE_ID:-dev.osholt.tideandseek}"
GROUP="${TIDE_AND_SEEK_BETA_GROUP:-Internal Testing}"
LOCALE="${TIDE_AND_SEEK_BETA_LOCALE:-en-GB}"
ISSUER_ID="${ASC_ISSUER_ID:-}"
KEY_ID="${ASC_KEY_ID:-}"
KEY_PATH="${ASC_PRIVATE_KEY:-$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8}"

DRY_RUN=0
case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  -h|--help)
    sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  "") ;;
  *) echo "release: unknown option $1 (try --dry-run or --help)" >&2; exit 2 ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mobile="$repo_root/apps/mobile"
notes="$repo_root/RELEASE_NOTES.md"
export_options="$repo_root/tools/release/ExportOptions.plist"
export_dir="$mobile/build/ios/release-upload"

die() { printf '\nrelease: %s\n' "$1" >&2; exit 1; }
step() { printf '\n==> %s\n' "$1"; }

[[ -f "$notes" ]] || die "RELEASE_NOTES.md is missing. Tester-facing notes live in the repo so they are reviewed in a pull request."

# The build number is the only source of truth for which build this is, and it
# is what App Store Connect keys on. Read it rather than passing it in, so the
# uploaded build and the committed pubspec cannot disagree.
version_line="$(grep -m1 '^version:' "$mobile/pubspec.yaml")"
marketing_version="${version_line#version: }"
build_number="${marketing_version##*+}"
marketing_version="${marketing_version%%+*}"
[[ -n "$build_number" && "$build_number" != "$marketing_version" ]] \
  || die "Cannot read a build number from pubspec.yaml ($version_line)"

printf 'Releasing %s (%s) of %s to "%s"\n' \
  "$marketing_version" "$build_number" "$BUNDLE_ID" "$GROUP"

step "Working tree"
# Two of the first three releases had their version bump travel inside an
# unrelated feature PR, because the release was cut from whatever branch
# happened to be checked out and a later branch inherited the commit. The end
# state was right both times and the history was not, so the tree is checked
# rather than trusted.
#
# A release branch is fine - `chore/build-N` is how these are made - but it must
# not be carrying anything other than the bump and the notes.
branch="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)"
dirty="$(git -C "$repo_root" status --porcelain \
  -- ':!RELEASE_NOTES.md' ':!apps/mobile/pubspec.yaml')"
if [[ -n "$dirty" ]]; then
  printf 'release: uncommitted changes outside the bump and the notes:\n%s\n' \
    "$dirty" >&2
  die "commit or stash them, so the build matches something reviewable"
fi
printf 'On %s, tree clean apart from the bump and the notes.\n' "$branch"

step "Tests and analysis"
( cd "$mobile" && flutter analyze && flutter test )

step "Archive"
# `flutter build ipa` archives correctly and then fails its own export step:
# the App Store profile must carry Push Notifications, and the Bundle ID has
# the capability with no provisioning profile behind it. The archive it leaves
# behind is good, so the failure is expected and swallowed here - the export
# below is the step that must succeed.
( cd "$mobile" && flutter build ipa --release ) || \
  echo 'release: flutter build ipa failed at export as expected; exporting with xcodebuild'

archive="$mobile/build/ios/archive/Runner.xcarchive"
[[ -d "$archive" ]] || die "No archive at $archive; the build failed before export"

step "Export a signed App Store build"
rm -rf "$export_dir"
# -allowProvisioningUpdates against **Xcode's signed-in account**, not the API
# key. Passing the API key here fails with "Cloud signing permission error":
# an App Manager key cannot do cloud signing, only upload.
xcodebuild -exportArchive \
  -archivePath "$archive" \
  -exportOptionsPlist "$export_options" \
  -exportPath "$export_dir" \
  -allowProvisioningUpdates

ipa="$(find "$export_dir" -name '*.ipa' -maxdepth 1 | head -1)"
[[ -n "$ipa" ]] || die "Export produced no .ipa in $export_dir"
printf 'Exported %s (%s)\n' "$(basename "$ipa")" "$(du -h "$ipa" | cut -f1)"

[[ -n "$ISSUER_ID" && -n "$KEY_ID" ]] || \
  die "Set ASC_ISSUER_ID and ASC_KEY_ID. The key must be App Manager or better; a Developer key cannot upload."
[[ -f "$KEY_PATH" ]] || die "No API key at $KEY_PATH"

step "Validate"
xcrun altool --validate-app -f "$ipa" -t ios \
  --apiKey "$KEY_ID" --apiIssuer "$ISSUER_ID"

if (( DRY_RUN )); then
  printf '\nrelease: --dry-run, stopping before upload. Validated %s\n' "$(basename "$ipa")"
  exit 0
fi

step "Upload"
xcrun altool --upload-app -f "$ipa" -t ios \
  --apiKey "$KEY_ID" --apiIssuer "$ISSUER_ID"

step "Publish to $GROUP"
# Processing, attaching and the notes are one Python step so its behaviour is
# testable - see tools/release/tests. In particular the notes are PATCHed when
# App Store Connect has already made an empty localisation, which it does for
# the app's primary locale without being asked.
python3 "$repo_root/tools/release/publish_internal.py" \
  --bundle-id "$BUNDLE_ID" \
  --build-number "$build_number" \
  --group "$GROUP" \
  --locale "$LOCALE" \
  --notes "$notes" \
  --issuer-id "$ISSUER_ID" \
  --key-id "$KEY_ID" \
  --private-key "$KEY_PATH"

printf '\nrelease: %s (%s) is live for "%s"\n' \
  "$marketing_version" "$build_number" "$GROUP"
