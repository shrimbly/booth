#!/usr/bin/env bash
# Builds everything a release publishes into dist/ at the repository root:
#   Booth-<version>.dmg   the disk image, for GitHub Releases
#   Booth.dmg             the same image under a stable name, for "latest" download links
#   booth.rb              the Homebrew cask (when packaging/release.env names the repository)
#   SHA256SUMS
# With --publish it then uploads them to the GitHub release v<version> and the cask to the Homebrew
# tap; otherwise nothing leaves this Mac. .github/workflows/release.yml runs the same script.
set -euo pipefail

usage() {
	cat <<'EOF'
usage: release.sh [--sign IDENTITY] [--notarize PROFILE] [--publish] [--skip-tests]

  --sign IDENTITY     a "Developer ID Application: …" identity for the app and the image.
                      Without it the app is signed with the local identity or ad hoc: fine for
                      testing the image, but Gatekeeper will refuse it on other Macs.
  --notarize PROFILE  notarize and staple the image (see make-dmg.sh); needs --sign
  --publish           upload the images and SHA256SUMS to the GitHub release v<version> (creating
                      it, and the tag, at this commit if they don't exist), then commit the cask
                      to the tap. Needs --sign, --notarize, a clean checkout and the GitHub CLI.
  --skip-tests        don't run the Swift tests and the engine's smoke checks first

environment (packaging/release.env holds the defaults):
  BOOTH_REPOSITORY    owner/name of the repository whose releases host the image
  BOOTH_HOMEPAGE      the cask's homepage               default: the repository
  BOOTH_TAP           owner/name of the Homebrew tap    default: none, so no cask is published
  BOOTH_TAP_REMOTE    the URL to push the tap to        default: https://github.com/$BOOTH_TAP.git
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
publish=false
run_tests=true
while (($# > 0)); do
	case $1 in
	--sign | --notarize)
		(($# > 1)) || die "$1 needs a value"
		[[ $1 == --sign ]] && sign_identity=$2 || notary_profile=$2
		shift
		;;
	--publish) publish=true ;;
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
tap_dir=
trap '[[ -z $tap_dir ]] || rm -rf "$tap_dir"' EXIT

# packaging/release.env holds the defaults; the environment wins over it.
repository=${BOOTH_REPOSITORY:-}
homepage=${BOOTH_HOMEPAGE:-}
tap=${BOOTH_TAP:-}
# shellcheck source=/dev/null
[[ -f $repo_dir/packaging/release.env ]] && source "$repo_dir/packaging/release.env"
BOOTH_REPOSITORY=${repository:-${BOOTH_REPOSITORY:-}}
BOOTH_HOMEPAGE=${homepage:-${BOOTH_HOMEPAGE:-}}
BOOTH_TAP=${tap:-${BOOTH_TAP:-}}

# --- 1. One version everywhere ---------------------------------------------------------------------

version=$(sed -n 's/^version = "\(.*\)"$/\1/p' "$repo_dir/pyproject.toml" | head -n 1)
engine_version=$(sed -n 's/^__version__ = "\(.*\)"$/\1/p' "$repo_dir/src/booth/__init__.py")
[[ -n $version ]] || die "no version in pyproject.toml"
[[ $version == "$engine_version" ]] ||
	die "pyproject.toml says $version but src/booth/__init__.py says $engine_version"
log "Releasing $version"

# Checked before the build, which takes a while: only a notarized image of a commit that is on
# GitHub goes out, and an existing tag must name that same commit.
if $publish; then
	[[ -n $sign_identity && -n $notary_profile ]] || die "--publish needs --sign and --notarize"
	[[ -n $BOOTH_REPOSITORY ]] || die "--publish needs BOOTH_REPOSITORY in packaging/release.env"
	command -v gh >/dev/null || die "--publish needs the GitHub CLI: brew install gh"
	[[ -z $(git -C "$repo_dir" status --porcelain) ]] ||
		die "the checkout has uncommitted changes; commit them first, so the release matches its tag"
	tag=v$version
	head=$(git -C "$repo_dir" rev-parse HEAD)
	tagged=$(gh api "repos/$BOOTH_REPOSITORY/commits/$tag" --jq .sha 2>/dev/null || true)
	if [[ -n $tagged ]]; then
		[[ $tagged == "$head" ]] || die "$tag is $tagged on GitHub, not this checkout's $head"
	else
		gh api "repos/$BOOTH_REPOSITORY/commits/$head" --silent 2>/dev/null ||
			die "$head isn't on GitHub yet; push it first"
	fi
fi

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

if [[ -n $BOOTH_REPOSITORY ]]; then
	homepage=${BOOTH_HOMEPAGE:-https://github.com/$BOOTH_REPOSITORY}
	sed -e "s|@VERSION@|$version|g" -e "s|@SHA256@|$sha|g" \
		-e "s|@REPOSITORY@|$BOOTH_REPOSITORY|g" -e "s|@HOMEPAGE@|$homepage|g" \
		"$repo_dir/packaging/homebrew/booth.rb.in" >"$dist/booth.rb"
	log "Cask: $dist/booth.rb"
else
	warn "BOOTH_REPOSITORY isn't set in packaging/release.env; skipped the Homebrew cask"
fi

# --- 5. Publish ------------------------------------------------------------------------------------

if $publish; then
	# A new release starts as a draft, which has no tag yet, and is published once the images are
	# up: nobody sees the release, or a tag that starts the release workflow, without them.
	if ! gh release view "$tag" --repo "$BOOTH_REPOSITORY" >/dev/null 2>&1; then
		log "Creating the release $tag"
		gh release create "$tag" --repo "$BOOTH_REPOSITORY" --draft --target "$head" \
			--title "Booth $version" --generate-notes >/dev/null
	fi
	log "Uploading to the release $tag"
	gh release upload "$tag" "$dmg" "$dist/Booth.dmg" "$dist/SHA256SUMS" --repo "$BOOTH_REPOSITORY" --clobber
	gh release edit "$tag" --repo "$BOOTH_REPOSITORY" --draft=false >/dev/null
	log "Published https://github.com/$BOOTH_REPOSITORY/releases/tag/$tag"

	# After the release, so the cask never points at an image that isn't there yet.
	if [[ -n $BOOTH_TAP ]]; then
		log "Updating the cask in $BOOTH_TAP"
		tap_dir=$(mktemp -d "${TMPDIR:-/tmp}/booth-tap.XXXXXX")
		git clone --quiet --depth 1 "${BOOTH_TAP_REMOTE:-https://github.com/$BOOTH_TAP.git}" "$tap_dir"
		mkdir -p "$tap_dir/Casks"
		cp "$dist/booth.rb" "$tap_dir/Casks/booth.rb"
		git -C "$tap_dir" add Casks/booth.rb
		if git -C "$tap_dir" diff --cached --quiet; then
			log "The cask is already up to date"
		else
			# As this repository's author, not whoever the global git config names.
			git -C "$tap_dir" -c user.name="$(git -C "$repo_dir" config user.name)" \
				-c user.email="$(git -C "$repo_dir" config user.email)" commit --quiet -m "booth $version"
			git -C "$tap_dir" push --quiet origin HEAD
		fi
	else
		warn "BOOTH_TAP isn't set in packaging/release.env; the tap's cask is unchanged"
	fi
fi

log "Done: $dist"
ls -l "$dist" >&2
printf '%s\n' "$dmg"
