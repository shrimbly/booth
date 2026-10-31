#!/usr/bin/env bash
# Puts what .github/workflows/release.yml signs, notarizes and publishes with into the repository's
# GitHub Actions secrets. Each part is optional, so a renewed certificate or a new API key can be
# replaced on its own:
#
#   --identity  MAC_CERTIFICATE_P12_BASE64, MAC_CERTIFICATE_PASSWORD
#   --api-key   APPLE_API_KEY_P8, APPLE_API_KEY_ID, APPLE_API_ISSUER
#   --tap-key   HOMEBREW_TAP_DEPLOY_KEY, and the matching deploy key on the tap
#
# Each one is checked before it is uploaded: the identity is exported and opened again, the API key
# signs in to the notary service.
set -euo pipefail

usage() {
	cat <<'EOF'
usage: set-release-secrets.sh [--identity IDENTITY] [--api-key FILE --issuer ID] [--tap-key]

  --identity IDENTITY  export this Developer ID Application identity from the keychain (its SHA-1
                       hash, or part of its name, as `security find-identity -v -p codesigning`
                       lists it), as a .p12 with a new random password. macOS asks for your login
                       password to let the private key out of the keychain.
  --api-key FILE       the App Store Connect API key, AuthKey_<KEY ID>.p8, for notarization
  --issuer ID          the key's issuer ID (App Store Connect › Users and Access › Integrations)
  --tap-key            make a new SSH key that can push to the Homebrew tap, replacing any earlier
                       one, and add it to the tap as a deploy key

The repository and the tap come from packaging/release.env (BOOTH_REPOSITORY, BOOTH_TAP).
EOF
}

log() { printf '==> %s\n' "$*" >&2; }
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

identity=
api_key=
issuer=
tap_key=false
while (($# > 0)); do
	case $1 in
	--identity | --api-key | --issuer)
		(($# > 1)) || die "$1 needs a value"
		case $1 in
		--identity) identity=$2 ;;
		--api-key) api_key=$2 ;;
		--issuer) issuer=$2 ;;
		esac
		shift
		;;
	--tap-key) tap_key=true ;;
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
[[ -n $identity || -n $api_key || $tap_key == true ]] || {
	usage >&2
	exit 64
}
[[ -z $api_key || -n $issuer ]] || die "--api-key needs --issuer"
[[ -z $issuer || -n $api_key ]] || die "--issuer goes with --api-key"

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd "$script_dir/../.." && pwd)
repository=${BOOTH_REPOSITORY:-}
tap=${BOOTH_TAP:-}
# shellcheck source=/dev/null
[[ -f $repo_dir/packaging/release.env ]] && source "$repo_dir/packaging/release.env"
repository=${repository:-${BOOTH_REPOSITORY:-}}
tap=${tap:-${BOOTH_TAP:-}}
[[ -n $repository ]] || die "no BOOTH_REPOSITORY in packaging/release.env"
command -v gh >/dev/null || die "the GitHub CLI is needed: brew install gh"

work=$(mktemp -d "${TMPDIR:-/tmp}/booth-secrets.XXXXXX")
trap 'rm -rf "$work"' EXIT
umask 077

secret() { gh secret set "$1" --repo "$repository" >/dev/null; }

# --- Developer ID identity -------------------------------------------------------------------------

if [[ -n $identity ]]; then
	# By SHA-1, as build-app.sh matches it: exactly one Developer ID Application identity.
	listed='^ *[0-9]+\) ([0-9A-F]{40}) "(Developer ID Application: .*)"$'
	hash=
	while IFS= read -r line; do
		[[ $line =~ $listed ]] || continue
		if [[ $(tr a-f A-F <<<"$identity") == "${BASH_REMATCH[1]}" || ${BASH_REMATCH[2]} == *"$identity"* ]]; then
			[[ -z $hash || $hash == "${BASH_REMATCH[1]}" ]] || die "more than one Developer ID identity matches \"$identity\"; give its SHA-1"
			hash=${BASH_REMATCH[1]}
			name=${BASH_REMATCH[2]}
		fi
	done < <(security find-identity -v -p codesigning)
	[[ -n $hash ]] || die "no valid Developer ID Application identity matches \"$identity\""

	log "Exporting $name (macOS asks for your login password)"
	password=$(/usr/bin/openssl rand -hex 24)
	# `security export` would take every identity in the keychain; SecItemExport takes just this one.
	cat >"$work/export.swift" <<'EOF'
import CryptoKit
import Foundation
import Security

let arguments = CommandLine.arguments
let (wanted, output, password) = (arguments[1], arguments[2], arguments[3] as CFString)
let query: [String: Any] = [
    kSecClass as String: kSecClassIdentity,
    kSecMatchLimit as String: kSecMatchLimitAll,
    kSecReturnRef as String: true,
]
var found: CFTypeRef?
guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let identities = found as? [SecIdentity] else {
    fatalError("no identities in the keychain")
}
for identity in identities {
    var certificate: SecCertificate?
    guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { continue }
    let sha1 = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data)
    guard sha1.map({ String(format: "%02X", $0) }).joined() == wanted else { continue }
    var parameters = SecItemImportExportKeyParameters()
    parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
    parameters.passphrase = Unmanaged.passUnretained(password as AnyObject)
    var data: CFData?
    let status = SecItemExport(identity, .formatPKCS12, [], &parameters, &data)
    guard status == errSecSuccess, let data else {
        fatalError("SecItemExport: \(SecCopyErrorMessageString(status, nil) as String? ?? "\(status)")")
    }
    try (data as Data).write(to: URL(fileURLWithPath: output))
    exit(0)
}
fatalError("\(wanted) isn't in the keychain")
EOF
	swift "$work/export.swift" "$hash" "$work/identity.p12" "$password" ||
		die "could not export the identity"
	# Opened again with the password, as the workflow will: the certificate and its private key.
	contents=$(/usr/bin/openssl pkcs12 -in "$work/identity.p12" -passin "pass:$password" -nodes 2>/dev/null) ||
		die "the exported .p12 doesn't open with its password"
	[[ $contents == *"PRIVATE KEY-----"* && $contents == *"BEGIN CERTIFICATE"* ]] ||
		die "the exported .p12 is missing the certificate or the private key"

	base64 -i "$work/identity.p12" | secret MAC_CERTIFICATE_P12_BASE64
	printf '%s' "$password" | secret MAC_CERTIFICATE_PASSWORD
	log "Set MAC_CERTIFICATE_P12_BASE64 and MAC_CERTIFICATE_PASSWORD"
fi

# --- App Store Connect API key ---------------------------------------------------------------------

if [[ -n $api_key ]]; then
	[[ -f $api_key ]] || die "no API key at $api_key"
	key_id=$(basename "$api_key" .p8)
	key_id=${key_id#AuthKey_}
	[[ $key_id =~ ^[A-Z0-9]{10}$ ]] || die "can't read the key ID from $(basename "$api_key"); keep Apple's name, AuthKey_<KEY ID>.p8"
	log "Checking the API key with the notary service"
	xcrun notarytool history --key "$api_key" --key-id "$key_id" --issuer "$issuer" >/dev/null ||
		die "the notary service refused the key $key_id with issuer $issuer"
	secret APPLE_API_KEY_P8 <"$api_key"
	printf '%s' "$key_id" | secret APPLE_API_KEY_ID
	printf '%s' "$issuer" | secret APPLE_API_ISSUER
	log "Set APPLE_API_KEY_P8, APPLE_API_KEY_ID and APPLE_API_ISSUER"
fi

# --- Homebrew tap deploy key -----------------------------------------------------------------------

if $tap_key; then
	[[ -n $tap ]] || die "no BOOTH_TAP in packaging/release.env"
	title="$repository release workflow"
	ssh-keygen -q -t ed25519 -N '' -C "$title" -f "$work/tap_key"
	for id in $(gh api "repos/$tap/keys" --jq ".[] | select(.title == \"$title\") | .id"); do
		gh api --method DELETE "repos/$tap/keys/$id" --silent
	done
	gh repo deploy-key add "$work/tap_key.pub" --repo "$tap" --title "$title" --allow-write >/dev/null
	secret HOMEBREW_TAP_DEPLOY_KEY <"$work/tap_key"
	log "Set HOMEBREW_TAP_DEPLOY_KEY, with a deploy key on $tap"
fi
