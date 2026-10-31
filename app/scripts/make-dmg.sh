#!/usr/bin/env bash
# Packages a built Booth.app as a drag-to-install disk image: Booth.app beside a link to
# /Applications. With --sign it signs the image; with --notarize it also sends the image to Apple's
# notary service and staples the ticket, which needs a Developer ID build (build-app.sh --dist
# --sign "Developer ID Application: …") and a notarytool keychain profile.
#
# Prints the disk image's path on stdout (progress goes to stderr).
set -euo pipefail

usage() {
	cat <<'EOF'
usage: make-dmg.sh [--app PATH] [--out DIR] [--sign IDENTITY] [--notarize PROFILE]

  --app PATH          the Booth.app to package     default: app/build/Booth.app
  --out DIR           where the image goes          default: app/build
  --sign IDENTITY     sign the image (a Developer ID Application identity)
  --notarize PROFILE  notarize and staple the image, with credentials saved once by
                      xcrun notarytool store-credentials PROFILE --apple-id … --team-id …

The image is named Booth-<version>.dmg, from the app's CFBundleShortVersionString.
EOF
}

log() { printf '==> %s\n' "$*" >&2; }
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
app=$script_dir/../build/Booth.app
out_dir=$script_dir/../build
sign_identity=
notary_profile=
while (($# > 0)); do
	case $1 in
	--app | --out | --sign | --notarize)
		(($# > 1)) || die "$1 needs a value"
		case $1 in
		--app) app=$2 ;;
		--out) out_dir=$2 ;;
		--sign) sign_identity=$2 ;;
		--notarize) notary_profile=$2 ;;
		esac
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		usage >&2
		die "unknown option $1"
		;;
	esac
	shift
done

[[ -d $app/Contents ]] || die "no app at $app; build it with build-app.sh first"
app=$(cd "$app" && pwd)
mkdir -p "$out_dir"
out_dir=$(cd "$out_dir" && pwd)
if [[ -n $notary_profile ]]; then
	[[ -n $sign_identity ]] || die "--notarize needs --sign: Apple only notarizes signed images"
	signature=$(codesign --display --verbose=2 "$app" 2>&1)
	[[ $signature == *"Authority=Developer ID Application"* ]] ||
		die "$app isn't signed with a Developer ID; build it with build-app.sh --dist --sign \"Developer ID Application: …\""
	# The notary service rejects a signature without one, but only after the upload.
	[[ $signature == *"Timestamp="* ]] ||
		die "$app's signature has no secure timestamp; build it again with build-app.sh --dist --sign \"Developer ID Application: …\""
fi

version=$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")
dmg=$out_dir/Booth-$version.dmg

staging=$(mktemp -d "${TMPDIR:-/tmp}/booth-dmg.XXXXXX")
trap 'rm -rf "$staging"' EXIT
log "Staging Booth $version"
ditto "$app" "$staging/Booth.app"
ln -s /Applications "$staging/Applications"

log "Creating $(basename "$dmg")"
rm -f "$dmg"
# ULFO (lzfse) is smaller and faster to open than zlib, and every macOS Booth runs on reads it.
hdiutil create -volname Booth -srcfolder "$staging" -fs HFS+ -format ULFO -ov "$dmg" >&2

if [[ -n $sign_identity ]]; then
	log "Signing the image as $sign_identity"
	codesign --force --timestamp --sign "$sign_identity" "$dmg"
	codesign --verify --verbose=2 "$dmg"
fi

if [[ -n $notary_profile ]]; then
	log "Notarizing (this usually takes a few minutes)"
	xcrun notarytool submit "$dmg" --keychain-profile "$notary_profile" --wait >&2
	xcrun stapler staple "$dmg" >&2
	spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
fi

hdiutil verify "$dmg" >/dev/null 2>&1 || die "hdiutil can't verify $dmg"
log "SHA-256 $(shasum -a 256 "$dmg" | awk '{ print $1 }')"
printf '%s\n' "$dmg"
