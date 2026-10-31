#!/usr/bin/env bash
# Builds everything a release publishes into dist/ at the repository root:
#   Booth-<version>.dmg   the disk image, for GitHub Releases
#   Booth.dmg             the same image under a stable name, for "latest" download links
#   booth.rb              the Homebrew cask (when packaging/release.env names the repository)
#   SHA256SUMS
# It also copies the image to site/downloads/Booth.dmg so the website's download link works when
# you preview the site locally. Nothing is uploaded or pushed.
set -euo pipefail

usage() {
	cat <<'EOF'
usage: release.sh [--sign IDENTITY] [--notarize PROFILE] [--skip-tests]

  --sign IDENTITY     a "Developer ID Application: …" identity for the app and the image.
                      Without it the app is signed with the local identity or ad hoc: fine for
                      testing the image, but Gatekeeper will refuse it on other Macs.
  --notarize PROFILE  notarize and staple the image (see make-dmg.sh); needs --sign
  --skip-tests        don't run the Swift tests and the engine's smoke checks first
EOF
}

log() { printf '==> %s\n' "$*" >&2; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

sign_identity=
notary_profile=
run_tests=true
while (($# > 0)); do
	case $1 in
	--sign | --notarize)
		(($# > 1)) || die "$1 needs a value"
		[[ $1 == --sign ]] && sign_identity=$2 || notary_profile=$2
		shift
		;;
	--skip-tests) run_tests=false ;;
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

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd "$script_dir/../.." && pwd)
dist=$repo_dir/dist

# --- 1. One version everywhere ---------------------------------------------------------------------

version=$(sed -n 's/^version = "\(.*\)"$/\1/p' "$repo_dir/pyproject.toml" | head -n 1)
engine_version=$(sed -n 's/^__version__ = "\(.*\)"$/\1/p' "$repo_dir/src/booth/__init__.py")
[[ -n $version ]] || die "no version in pyproject.toml"
[[ $version == "$engine_version" ]] ||
	die "pyproject.toml says $version but src/booth/__init__.py says $engine_version"
log "Releasing $version"

# --- 2. Tests --------------------------------------------------------------------------------------

if $run_tests; then
	log "Swift tests"
	swift test --package-path "$repo_dir/app" >&2
	if [[ -x $repo_dir/.venv/bin/booth ]]; then
		log "Engine smoke checks"
		"$repo_dir/.venv/bin/booth" --version >&2
		"$repo_dir/.venv/bin/booth" app-info >/dev/null
		"$repo_dir/.venv/bin/booth" --help >/dev/null
	else
		warn "no .venv; skipping the engine smoke checks"
	fi
fi

# --- 3. App and disk image ------------------------------------------------------------------------

build_args=(--dist)
dmg_args=(--out "$dist")
if [[ -n $sign_identity ]]; then
	build_args+=(--sign "$sign_identity")
	dmg_args+=(--sign "$sign_identity")
else
	warn "no --sign: this image is for testing; Gatekeeper will block it on other Macs"
fi
[[ -z $notary_profile ]] || dmg_args+=(--notarize "$notary_profile")

mkdir -p "$dist"
# Its own build folder, so app/build/Booth.app stays the development build that uses this
# checkout's engine.
export BOOTH_BUILD_DIR=${BOOTH_BUILD_DIR:-$repo_dir/app/build/release}
app=$("$script_dir/build-app.sh" "${build_args[@]}")
dmg=$("$script_dir/make-dmg.sh" --app "$app" "${dmg_args[@]}")
cp "$dmg" "$dist/Booth.dmg"
sha=$(shasum -a 256 "$dmg" | awk '{ print $1 }')
(cd "$dist" && shasum -a 256 "$(basename "$dmg")" Booth.dmg >SHA256SUMS)

# --- 4. Homebrew cask ------------------------------------------------------------------------------

# packaging/release.env holds the defaults; the environment wins over it.
repository=${BOOTH_REPOSITORY:-}
homepage=${BOOTH_HOMEPAGE:-}
# shellcheck source=/dev/null
[[ -f $repo_dir/packaging/release.env ]] && source "$repo_dir/packaging/release.env"
BOOTH_REPOSITORY=${repository:-${BOOTH_REPOSITORY:-}}
BOOTH_HOMEPAGE=${homepage:-${BOOTH_HOMEPAGE:-}}
if [[ -n $BOOTH_REPOSITORY ]]; then
	homepage=${BOOTH_HOMEPAGE:-https://github.com/$BOOTH_REPOSITORY}
	sed -e "s|@VERSION@|$version|g" -e "s|@SHA256@|$sha|g" \
		-e "s|@REPOSITORY@|$BOOTH_REPOSITORY|g" -e "s|@HOMEPAGE@|$homepage|g" \
		"$repo_dir/packaging/homebrew/booth.rb.in" >"$dist/booth.rb"
	log "Cask: $dist/booth.rb"
else
	warn "BOOTH_REPOSITORY isn't set in packaging/release.env; skipped the Homebrew cask"
fi

# --- 5. The website's download --------------------------------------------------------------------

mkdir -p "$repo_dir/site/downloads"
cp "$dmg" "$repo_dir/site/downloads/Booth.dmg"

log "Done: $dist"
ls -l "$dist" >&2
printf '%s\n' "$dmg"
