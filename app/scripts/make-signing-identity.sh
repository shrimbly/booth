#!/usr/bin/env bash
# Creates a self-signed code-signing identity for local Booth builds, once. build-app.sh signs with
# it whenever it exists, so every build has the same designated requirement and macOS keeps the
# permissions (Documents, Finder automation) it gave the last build instead of asking again.
#
# The identity lives in its own keychain, outside the repo and off the keychain search list, so it
# never shows up in Keychain Access or in Xcode's signing menus. It is only good for this Mac: it is
# not trusted by Gatekeeper and can't be used to ship Booth. To remove it, delete the folder.
set -euo pipefail

log() { printf '==> %s\n' "$*" >&2; }
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

signing_dir=${BOOTH_SIGNING_DIR:-$HOME/Library/Application Support/Booth Signing}
keychain=$signing_dir/signing.keychain-db
identity="Booth Local Signing"

if [[ -f $keychain ]]; then
	log "The signing identity already exists in $keychain"
	exit 0
fi
command -v security >/dev/null || die "security not found"

mkdir -p "$signing_dir"
chmod 700 "$signing_dir"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
umask 077

# The keychain's password only keeps the key locked at rest; the build script reads it from here.
password=$(/usr/bin/openssl rand -hex 24)
printf '%s' "$password" >"$signing_dir/password"

log "Creating the certificate \"$identity\""
cat >"$work/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $identity
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
# /usr/bin/openssl is LibreSSL, whose PKCS#12 files `security import` can read; OpenSSL 3's
# default ciphers it can't.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/cert.cnf" \
	-keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
	-name "$identity" -passout "pass:$password" -out "$work/identity.p12"

log "Creating the keychain $keychain"
# Creating a keychain can add it to the search list; put the list back as it was.
search_list=()
while IFS= read -r line; do
	line=${line#"${line%%[![:space:]]*}"}
	line=${line#\"}
	search_list+=("${line%\"}")
done < <(security list-keychains -d user)
security create-keychain -p "$password" "$keychain"
security list-keychains -d user -s "${search_list[@]}"
security set-keychain-settings "$keychain" # never locks on a timer
security unlock-keychain -p "$password" "$keychain"
security import "$work/identity.p12" -k "$keychain" -P "$password" -T /usr/bin/codesign >/dev/null
# Lets codesign use the key without a keychain prompt.
security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$keychain" >/dev/null

log "Created \"$identity\"; build-app.sh will sign with it from now on"
