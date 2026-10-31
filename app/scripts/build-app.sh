#!/usr/bin/env bash
# Builds Booth.app from the SwiftPM package in app/: compiles it, renders the icon, assembles the
# bundle with the engine source, uv, the booth command and the license notices inside, signs
# it with the hardened runtime and verifies the result. It signs with the local identity from
# make-signing-identity.sh when there is one, otherwise ad hoc, unless --sign. Safe to run
# repeatedly; every run reassembles the bundle from scratch. make-dmg.sh packages the result;
# release.sh does both for a release.
#
# Prints the finished .app's path on stdout (progress goes to stderr), so `app=$(build-app.sh)` works.
set -euo pipefail

usage() {
	cat <<'EOF'
usage: build-app.sh [--debug] [--dist] [--install] [--open] [--sign IDENTITY]

  --debug          build the debug configuration instead of release
  --dist           build for other Macs: don't point Booth at this checkout's engine, strip the
                   debug map (it names this Mac's build folder), and require a bundled uv. With a
                   Developer ID identity (by name or by hash), signatures get a secure timestamp.
  --install        copy the app to ~/Applications/Booth.app (quits a Booth running from there first)
  --open           launch the app when done (the installed copy with --install)
  --sign IDENTITY  sign with this keychain identity (as `security find-identity -v -p codesigning`
                   lists it), or - for ad hoc. Without it, Booth is signed with the local identity
                   from make-signing-identity.sh if you made one, and ad hoc otherwise. An ad hoc
                   signature changes with every build, so macOS asks again for permissions it gave
                   the last one; any other identity keeps them.

environment (mostly for testing this script):
  BOOTH_PACKAGE_DIR  SwiftPM package to build          default: the app/ folder holding this script
  BOOTH_BUILD_DIR    where Booth.app and the icon go   default: $BOOTH_PACKAGE_DIR/build
  BOOTH_REPO_DIR     Booth checkout to bundle    default: the repo holding this script
  BOOTH_INSTALL_DIR  --install destination             default: ~/Applications
  BOOTH_UV           uv binary to bundle               default: `command -v uv`; set it empty to skip
  BOOTH_SIGN_IDENTITY  as --sign                       default: the local identity, else ad hoc
  BOOTH_SIGNING_DIR  the local identity's folder       default: ~/Library/Application Support/Booth Signing
  BOOTH_BUILD_NUMBER CFBundleVersion                   default: the commit count, else 1
EOF
}

log() { printf '==> %s\n' "$*" >&2; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

configuration=release
distribution=false
install=false
open_when_done=false
sign_identity=${BOOTH_SIGN_IDENTITY:-}
while (($# > 0)); do
	case $1 in
	--debug) configuration=debug ;;
	--dist) distribution=true ;;
	--install) install=true ;;
	--open) open_when_done=true ;;
	--sign)
		(($# > 1)) || die "--sign needs an identity"
		sign_identity=$2
		shift
		;;
	--sign=*) sign_identity=${1#--sign=} ;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		usage >&2
		printf 'error: unknown option %s\n' "$1" >&2
		exit 64
		;;
	esac
	shift
done
# The absolute path of an existing directory.
absolute_dir() {
	if [[ -d $1 ]]; then
		(cd "$1" && pwd)
	else
		die "no such directory: $1"
	fi
}

script_dir=$(absolute_dir "$(dirname "${BASH_SOURCE[0]}")")
app_dir=$(dirname "$script_dir")
package_dir=$(absolute_dir "${BOOTH_PACKAGE_DIR:-$app_dir}")
repo_dir=$(absolute_dir "${BOOTH_REPO_DIR:-$(dirname "$app_dir")}")
resources=$package_dir/Resources

for tool in swift codesign plutil iconutil rsync ditto lipo strip; do
	command -v "$tool" >/dev/null || die "$tool not found; install the Command Line Tools with xcode-select --install"
done
[[ -f $package_dir/Package.swift ]] || die "no Package.swift in $package_dir"
[[ -f $resources/Info.plist ]] || die "no Info.plist template in $resources"
[[ -d $resources/Fonts ]] || die "no Fonts folder in $resources"
[[ -f $resources/Booth.entitlements ]] || die "no Booth.entitlements in $resources"
[[ -x $resources/bin/booth ]] || die "no executable bin/booth in $resources"
for path in src/booth pyproject.toml uv.lock README.md; do
	[[ -e $repo_dir/$path ]] || die "the engine source is incomplete: $repo_dir/$path is missing"
done
for path in LICENSE THIRD_PARTY_NOTICES.md; do
	[[ -f $repo_dir/$path ]] || die "no $path in $repo_dir; Booth.app must carry it"
done

mkdir -p "${BOOTH_BUILD_DIR:-$package_dir/build}"
build_dir=$(absolute_dir "${BOOTH_BUILD_DIR:-$package_dir/build}")
install_dir=${BOOTH_INSTALL_DIR:-$HOME/Applications}
bundle=$build_dir/Booth.app
signing_dir=${BOOTH_SIGNING_DIR:-$HOME/Library/Application Support/Booth Signing}
signing_keychain=$signing_dir/signing.keychain-db

staging=
saved_keychains=()
cleanup() {
	[[ -z $staging ]] || rm -rf "$staging"
	restore_keychains
}
trap cleanup EXIT

# True when IDENTITY, given as codesign takes it (a SHA-1 hash, or part of the certificate's name),
# is a Developer ID Application certificate on the keychain search list.
is_developer_id() {
	local wanted=$1 line hash name
	local listed='^ *[0-9]+\) ([0-9A-F]{40}) "(.*)"$' sha1='^[0-9A-Fa-f]{40}$'
	while IFS= read -r line; do
		[[ $line =~ $listed ]] || continue
		hash=${BASH_REMATCH[1]}
		name=${BASH_REMATCH[2]}
		if [[ $wanted =~ $sha1 ]]; then
			[[ $(tr a-f A-F <<<"$wanted") == "$hash" ]] || continue
		else
			[[ $name == *"$wanted"* ]] || continue
		fi
		if [[ $name == "Developer ID Application:"* ]]; then return 0; fi
	done < <(security find-identity -v -p codesigning)
	return 1
}

# codesign only finds identities in keychains on the search list, and the local identity's keychain
# stays off it. These add it just for the signing, then put the list back as it was.
add_signing_keychain() {
	local line
	while IFS= read -r line; do
		line=${line#"${line%%[![:space:]]*}"}
		line=${line#\"}
		saved_keychains+=("${line%\"}")
	done < <(security list-keychains -d user)
	security list-keychains -d user -s "${saved_keychains[@]}" "$signing_keychain"
}
restore_keychains() {
	((${#saved_keychains[@]} == 0)) && return 0
	security list-keychains -d user -s "${saved_keychains[@]}" || warn "could not restore the keychain search list"
	saved_keychains=()
}

# Stops a Booth running from exactly this bundle so a reinstall or relaunch runs the new build.
# SIGTERM goes through NSApp.terminate, which cancels running engines before quitting.
stop_running_booth() {
	local executable=$1/Contents/MacOS/Booth pattern pids
	pattern="^${executable//./\\.}( |\$)"
	pids=$(pgrep -f "$pattern" || true)
	[[ -n $pids ]] || return 0
	log "Quitting the Booth running from $1"
	# shellcheck disable=SC2086 # one pid per word
	kill -TERM $pids 2>/dev/null || true
	for _ in {1..50}; do
		pgrep -f "$pattern" >/dev/null || return 0
		sleep 0.1
	done
	die "Booth (pid $pids) did not quit; quit it from its menu and run again"
}

# --- 1. Compile ------------------------------------------------------------------------------------

log "Building Booth ($configuration) in $package_dir"
swift build --package-path "$package_dir" --configuration "$configuration" --product Booth >&2
executable=$(swift build --package-path "$package_dir" --configuration "$configuration" --show-bin-path)/Booth
[[ -x $executable ]] || die "swift build left no executable at $executable"

# --- 2. Icon (re-rendered only when make-icon.swift changes) ---------------------------------------

icon_dir=$build_dir/icon
if [[ ! -f $icon_dir/Booth.icns || $script_dir/make-icon.swift -nt $icon_dir/Booth.icns ]]; then
	log "Rendering the app icon"
	swift "$script_dir/make-icon.swift" "$icon_dir" >/dev/null
fi

# --- 3. Assemble in a staging folder, so a failed run never leaves a half-built bundle -------------

staging=$build_dir/.staging
rm -rf "$staging"
staged_bundle=$staging/Booth.app
contents=$staged_bundle/Contents
mkdir -p "$contents/MacOS" "$contents/Resources"

log "Assembling Booth.app"
cp "$executable" "$contents/MacOS/Booth"
if $distribution; then
	# The debug map names every object file by its path on this Mac, user name included; a
	# shipped binary has no use for it.
	strip -S "$contents/MacOS/Booth"
fi
printf 'APPL????' >"$contents/PkgInfo"
cp "$icon_dir/Booth.icns" "$contents/Resources/Booth.icns"
rsync -a --exclude .DS_Store "$resources/Fonts/" "$contents/Resources/Fonts/"
# Booth's license, and the notices for what it redistributes (uv, Geist Serif).
cp "$repo_dir/LICENSE" "$repo_dir/THIRD_PARTY_NOTICES.md" "$contents/Resources/"

plist=$contents/Info.plist
cp "$resources/Info.plist" "$plist"
plutil -convert xml1 "$plist" # normalises the file and drops the template's comments
# One version for the app and the engine: pyproject.toml's.
version=$(sed -n 's/^version = "\(.*\)"$/\1/p' "$repo_dir/pyproject.toml" | head -n 1)
[[ -n $version ]] || die "no version in $repo_dir/pyproject.toml"
build_number=${BOOTH_BUILD_NUMBER:-$(git -C "$repo_dir" rev-list --count HEAD 2>/dev/null || echo 1)}
plutil -replace CFBundleShortVersionString -string "$version" "$plist"
plutil -replace CFBundleVersion -string "$build_number" "$plist"
log "Version $version ($build_number)"
engine=$repo_dir/.venv/bin/booth
if $distribution; then
	log "Distribution build: Booth will find or install its own engine"
elif [[ -x $engine ]]; then
	plutil -replace BoothEnginePath -string "$engine" "$plist"
	log "Engine: $engine (BoothEnginePath)"
else
	warn "no engine at $engine; Booth will search for one and offer to install it on first run"
fi

# The managed engine install (first-run setup) is created from this copy with `uv sync --frozen`.
engine_source=$contents/Resources/engine
mkdir -p "$engine_source"
rsync -a --exclude __pycache__/ --exclude '*.pyc' --exclude '*.egg-info/' --exclude .DS_Store \
	"$repo_dir/src/" "$engine_source/src/"
cp "$repo_dir/pyproject.toml" "$repo_dir/uv.lock" "$repo_dir/README.md" "$engine_source/"
# Booth and the booth command update an install whose BUILD differs, so a rebuilt engine
# reaches existing installs even when the version number stays the same.
engine_hash=$(cd "$engine_source" && find src pyproject.toml uv.lock -type f -print0 | LC_ALL=C sort -z |
	xargs -0 shasum -a 256 | shasum -a 256 | cut -c1-12)
printf '%s+%s\n' "$version" "$engine_hash" >"$engine_source/BUILD"

mkdir -p "$contents/Resources/bin"
# `booth` for the terminal: Homebrew's cask links it onto PATH.
cp "$resources/bin/booth" "$contents/Resources/bin/booth"
uv=${BOOTH_UV-$(command -v uv || true)}
if [[ -n $uv ]]; then
	[[ -x $uv ]] || die "uv at $uv is not executable"
	cp -L "$uv" "$contents/Resources/bin/uv" # -L: Homebrew's uv is a symlink into the Cellar
	[[ $(lipo -archs "$contents/Resources/bin/uv") == *arm64* ]] || die "uv at $uv has no arm64 slice"
	log "uv: $("$uv" --version) from $uv"
elif $distribution; then
	die "a --dist build must bundle uv (install it with brew install uv, or set BOOTH_UV)"
else
	warn "uv not bundled; a first-run engine install will need uv on PATH"
fi

# --- 4. Sign and verify ----------------------------------------------------------------------------

if [[ -z $sign_identity && -f $signing_keychain ]]; then
	security unlock-keychain -p "$(cat "$signing_dir/password")" "$signing_keychain" ||
		die "could not unlock $signing_keychain; delete $signing_dir and run make-signing-identity.sh again"
	# By hash: codesign won't look up an identity macOS doesn't trust by its name.
	sign_identity=$(security find-identity -p codesigning "$signing_keychain" | awk '/"Booth Local Signing"/ { print $2; exit }')
	[[ -n $sign_identity ]] ||
		die "no Booth Local Signing identity in $signing_keychain; delete $signing_dir and run make-signing-identity.sh again"
	log "Signing with Booth Local Signing"
	add_signing_keychain
elif [[ -z $sign_identity || $sign_identity == - ]]; then
	sign_identity=-
	log "Signing ad hoc; macOS will ask again for its permissions. Run make-signing-identity.sh once to stop that"
else
	log "Signing as $sign_identity"
fi
# Inside out, with the hardened runtime notarization requires. The entitlements are the app's
# alone, so uv is signed on its own first rather than with --deep. A secure timestamp needs Apple's
# server and only matters for a Developer ID build that will be notarized; that is decided by the
# certificate, since the identity may be given by its hash.
timestamp=--timestamp=none
if [[ $sign_identity != - ]] && is_developer_id "$sign_identity"; then
	timestamp=--timestamp
fi
if [[ -f $contents/Resources/bin/uv ]]; then
	codesign --force --options runtime "$timestamp" --sign "$sign_identity" "$contents/Resources/bin/uv"
fi
codesign --force --options runtime "$timestamp" --entitlements "$resources/Booth.entitlements" \
	--sign "$sign_identity" "$staged_bundle"
restore_keychains

log "Verifying"
plutil -lint "$plist" >&2
for key in CFBundleIdentifier CFBundleExecutable CFBundleShortVersionString CFBundleIconFile LSUIElement \
	ATSApplicationFontsPath NSAppleEventsUsageDescription NSServices CFBundleDocumentTypes; do
	plutil -extract "$key" xml1 -o /dev/null "$plist" || die "Info.plist has no $key"
done
# AppKit calls the service's NSMessage as an Objective-C selector on NSApp.servicesProvider; a name
# that matches no method makes the Quick Action silently do nothing.
service_message=$(plutil -extract NSServices.0.NSMessage raw -o - "$plist")
grep -q "func $service_message(" "$package_dir/Sources/Booth/Shell/ServicesProvider.swift" ||
	die "NSServices NSMessage '$service_message' has no matching method in ServicesProvider.swift"
codesign --verify --deep --strict --verbose=2 "$staged_bundle"
# Captured first: with pipefail, grep -q closing the pipe early would fail the check.
signed_entitlements=$(codesign --display --entitlements - --xml "$staged_bundle" 2>/dev/null)
[[ $signed_entitlements == *com.apple.security.automation.apple-events* ]] ||
	die "the signature is missing the Apple Events entitlement"
# The flags read (runtime) with a certificate and (adhoc,runtime) ad hoc. Notarization checks
# every binary, so uv too.
hardened='flags=0x[0-9a-f]+\(([^)]*,)?runtime[,)]'
for signed in "$staged_bundle" "$contents/Resources/bin/uv"; do
	[[ -e $signed ]] || continue
	signature=$(codesign --display --verbose=2 "$signed" 2>&1)
	[[ $signature =~ $hardened ]] || die "${signed##*/}'s signature is missing the hardened runtime"
	if [[ $signature == *"Authority=Developer ID Application:"* && $signature != *Timestamp=* ]]; then
		die "${signed##*/}'s Developer ID signature has no secure timestamp, which notarization needs"
	fi
done
log "Architectures: $(lipo -archs "$contents/MacOS/Booth")"

rm -rf "$bundle"
mv "$staged_bundle" "$bundle"
log "Built $bundle"

# --- 5. Install and launch -------------------------------------------------------------------------

final=$bundle
if $install; then
	final=$install_dir/Booth.app
	mkdir -p "$install_dir"
	stop_running_booth "$final"
	rm -rf "$final"
	ditto "$bundle" "$final"
	# Register now so Open With and the "Enhance with Booth" Quick Action find this copy right away.
	lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
	"$lsregister" -f "$final" || warn "lsregister failed; Open With may take a while to list Booth"
	/System/Library/CoreServices/pbs -update || warn "could not refresh the Services menu"
	log "Installed $final"
fi

if $open_when_done; then
	stop_running_booth "$final"
	log "Opening $final"
	open "$final"
fi

printf '%s\n' "$final"
