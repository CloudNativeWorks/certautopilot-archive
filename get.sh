#!/usr/bin/env bash
# CertAutoPilot standalone bootstrap.
#
# Pulls the pinned release tarball from the public GHCR OCI package
# (ghcr.io/cloudnativeworks/standalone/certautopilot), verifies its
# sha256 checksum, extracts the bundle, and hands off to the bundled
# install.sh with every extra flag forwarded.
#
# The repo that ships this bootstrap is PUBLIC on purpose — the main
# certautopilot repo stays private, while the OCI package + this tiny
# launcher are the only public entry points. Same pattern as the
# existing Helm chart under ghcr.io/cloudnativeworks/charts.
#
# Usage (typical):
#   curl -fsSL https://raw.githubusercontent.com/CloudNativeWorks/certautopilot-archive/main/get.sh \
#     | sudo bash -s -- --version=1.3.12 --mongo=local
#
# Usage with external MongoDB:
#   curl -fsSL https://raw.githubusercontent.com/CloudNativeWorks/certautopilot-archive/main/get.sh \
#     | sudo bash -s -- --version=1.3.12 \
#         --mongo=external \
#         --mongo-uri="mongodb://user:pass@db.example.com:27017/?authSource=admin"
#
# Every flag after --version is forwarded verbatim to the bundled
# install.sh, so anything install.sh supports (--port, --bind-host,
# --tls=provided, --cert, --key, --extra-hostnames, --no-firewall,
# --non-interactive, --backend-port, …) works here too.
#
# Required environment: root + curl + tar + awk + sha256sum + openssl.
# On a fresh Debian/Ubuntu/RHEL/Oracle/Rocky/Alma host these are all
# already present.

set -Eeuo pipefail

GHCR_REPO=${GHCR_REPO:-cloudnativeworks/standalone/certautopilot}

print_help() {
  cat <<'EOF'
CertAutoPilot standalone bootstrap.

Usage:
  curl -fsSL https://raw.githubusercontent.com/CloudNativeWorks/certautopilot-archive/main/get.sh \
    | sudo bash -s -- --version=<pinned> [install.sh flags...]

Required:
  --version=<pinned>    Pinned release (e.g. 1.3.12). No "latest" auto-resolve.

Forwarded to install.sh (any of these work):
  --mongo=local|external
  --mongo-uri=<uri>                 Required with --mongo=external
  --mongo-version=<ver>             Default: 7.0
  --tls=self-signed|provided        Default: self-signed (10-year ECDSA-P256)
  --cert=<path> --key=<path>        Required with --tls=provided
  --port=<n>                        Public HTTPS port (default: 443)
  --backend-port=<n>                Loopback port on the backend (default: 18181)
  --bind-host=<host>                Bind address (default: 0.0.0.0)
  --extra-hostnames=a,b,c           Extra DNS SAN entries
  --kek-provider=env|pkcs11         Default: env. pkcs11 locks the install
                                    to an HSM-backed provider (see below).
  --pkcs11-module=<path>            Vendor PKCS#11 shared library (required
                                    with --kek-provider=pkcs11).
  --pkcs11-token-label=<lbl>        HSM token label (required with pkcs11).
  --pkcs11-pin=<value>              HSM user PIN inline (argv-visible during
                                    install only; persists afterward only in
                                    /etc/certautopilot/secrets.env mode 0600).
  --pkcs11-pin-file=<path>          HSM user PIN read from a mode-0600 file
                                    (recommended for production — the PIN
                                    never appears in argv or shell history).
  --secrets-from=<path>             Adopt an existing /etc/certautopilot/
                                    secrets.env verbatim instead of minting
                                    fresh KEK/JWT/pepper. REQUIRED on the
                                    2nd+ host of a multi-VM deployment that
                                    shares one external MongoDB — otherwise
                                    each host would generate its own KEK and
                                    be unable to decrypt data written by the
                                    others.
  --no-firewall                     Skip firewalld / ufw port-opening
  --non-interactive                 Never prompt
  --enable-backup                   Install the nightly mongodump timer
                                    (03:15 local, 7-day retention under
                                    /var/backups/certautopilot/). Opt-in;
                                    off by default. Only honored with
                                    --mongo=local — external deployments
                                    own their backup stack.

Pick a KEK backend before installing — the choice (env vs pkcs11) is
immutable after first install (locked in MongoDB via the kek_install
singleton). env: raw hex bytes in /etc/certautopilot/secrets.env (no
HSM needed). pkcs11: AES key lives inside an HSM token, never leaves
the device (requires the vendor PKCS#11 SDK on the host). Changing
provider later requires a planned migration — see the provider-migration
guide on https://certautopilot.com/docs/encryption/provider-migration.html.

Examples:
  # Env provider, local MongoDB:
  sudo bash -s -- --version=1.3.12 --mongo=local

  # Env provider, external MongoDB:
  sudo bash -s -- --version=1.3.12 --mongo=external \
                  --mongo-uri="mongodb://user:pass@db:27017/?authSource=admin"

  # Env provider, local MongoDB + nightly mongodump backup timer:
  sudo bash -s -- --version=1.3.12 --mongo=local --enable-backup

  # Env provider, provided TLS cert:
  sudo bash -s -- --version=1.3.12 --mongo=local \
                  --tls=provided --cert=/etc/ssl/certs/foo.pem --key=/etc/ssl/private/foo.key

  # PKCS#11 provider, inline PIN (quick-and-dirty — PIN in argv during install):
  sudo bash -s -- --version=1.3.12 --mongo=local \
                  --kek-provider=pkcs11 \
                  --pkcs11-module=/usr/lib/softhsm/libsofthsm2.so \
                  --pkcs11-token-label=certautopilot-prod \
                  --pkcs11-pin='<HSM_USER_PIN>'

  # PKCS#11 provider, PIN from a mode-0600 file (production-grade):
  umask 077 && printf '%s' "$HSM_PIN" > /tmp/cap-pin
  sudo bash -s -- --version=1.3.12 --mongo=local \
                  --kek-provider=pkcs11 \
                  --pkcs11-module=/opt/thales/lib/libCryptoki2_64.so \
                  --pkcs11-token-label=certautopilot \
                  --pkcs11-pin-file=/tmp/cap-pin
  shred -u /tmp/cap-pin

  # Multi-VM: second host joining the same external MongoDB, adopting the
  # first host's secrets.env (copy it over beforehand with scp).
  sudo bash -s -- --version=1.3.12 --mongo=external \
                  --mongo-uri="mongodb://user:pass@db:27017/?authSource=admin" \
                  --secrets-from=/tmp/cap-shared-secrets.env

Notes:
  * MongoDB connection strings must be URL-encoded per RFC 3986. Raw '@',
    ':', '/', '?', '#', or '%' inside the username or password will break
    URI parsing — percent-encode them (e.g. 'p@ss' -> 'p%40ss'). See
    https://www.mongodb.com/docs/manual/reference/connection-string/.
  * The PKCS#11 vendor SDK (SoftHSM2, Thales Luna client, AWS CloudHSM
    client, Fortanix DSM, etc.) must be installed separately before
    invoking this bootstrap — each vendor has its own install procedure.
    See https://certautopilot.com/docs/encryption/pkcs11-vendors.html.
  * The PIN persists in /etc/certautopilot/secrets.env (0600, owned by
    the certautopilot service user). Systemd loads it via EnvironmentFile
    on every service start, so restarts and reboots keep working without
    re-supplying the PIN.
  * The service runs as a dedicated non-root system user (certautopilot).
    Root is required only for install, update, and uninstall scripts.

Docs:
  https://github.com/CloudNativeWorks/certautopilot-archive
EOF
}

VERSION=""
INSTALL_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --version=*)
      VERSION=${1#*=}
      ;;
    --version)
      VERSION=${2:-}
      shift
      ;;
    --help|-h)
      print_help
      exit 0
      ;;
    *)
      INSTALL_ARGS+=("$1")
      ;;
  esac
  shift
done

if [ -z "$VERSION" ]; then
  printf 'error: --version=<pinned> is required (example: --version=1.3.12)\n' >&2
  printf 'no latest auto-resolve — every install pins an explicit version.\n' >&2
  exit 2
fi

if [ "$(id -u)" -ne 0 ]; then
  printf 'error: must run as root (use: sudo bash -s -- --version=%s ...)\n' "$VERSION" >&2
  exit 2
fi

for cmd in curl tar awk sha256sum sed grep; do
  command -v "$cmd" >/dev/null 2>&1 || { printf 'error: required command not found: %s\n' "$cmd" >&2; exit 2; }
done

ARCH_RAW=$(uname -m)
case "$ARCH_RAW" in
  x86_64|amd64)
    ARCH=amd64
    ;;
  *)
    printf 'error: unsupported architecture %s — only linux_amd64 is published\n' "$ARCH_RAW" >&2
    exit 2
    ;;
esac

TARBALL="certautopilot_${VERSION}_linux_${ARCH}.tar.gz"
CHECKSUMS="certautopilot_${VERSION}_checksums.txt"

echo "[get] requesting anonymous GHCR pull token for ${GHCR_REPO}"
TOKEN_JSON=$(curl -fsSL \
  "https://ghcr.io/token?scope=repository:${GHCR_REPO}:pull&service=ghcr.io") \
  || { printf 'error: failed to obtain GHCR token — is the package public?\n' >&2; exit 1; }

TOKEN=$(printf '%s' "$TOKEN_JSON" \
  | grep -oE '"token":"[^"]+"' | head -n1 | sed 's/"token":"\(.*\)"/\1/')
if [ -z "$TOKEN" ]; then
  TOKEN=$(printf '%s' "$TOKEN_JSON" \
    | grep -oE '"access_token":"[^"]+"' | head -n1 | sed 's/"access_token":"\(.*\)"/\1/')
fi
[ -n "$TOKEN" ] || { printf 'error: could not parse GHCR token from response\n' >&2; exit 1; }

echo "[get] fetching manifest ${GHCR_REPO}:${VERSION}"
MANIFEST=$(curl -fsSL \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/vnd.oci.image.manifest.v1+json" \
  -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
  "https://ghcr.io/v2/${GHCR_REPO}/manifests/${VERSION}") \
  || { printf 'error: manifest fetch failed for %s:%s\n' "$GHCR_REPO" "$VERSION" >&2; exit 1; }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# pull_blob <title-annotation> <dest>
#
# Walks the OCI manifest's layers[] array looking for a layer whose
# org.opencontainers.image.title annotation matches <title-annotation>,
# then downloads that layer's blob to <dest>.
#
# OCI manifests nest the title inside an annotations:{} sub-object, so
# a naive '{[^{}]*title[^{}]*}' regex can't jump across the inner brace.
# Instead we isolate the layers array, split on the `},{` boundary
# between layer objects, and — within each matched part — take the LAST
# `"digest":"sha256:..."` match. Taking the LAST match handles parts[1],
# which also carries the manifest preamble's config.digest.
pull_blob() {
  local title=$1 dest=$2 digest
  digest=$(printf '%s' "$MANIFEST" | tr '\n' ' ' | awk -v want="$title" '
    {
      idx = index($0, "\"layers\":[")
      if (idx == 0) exit 1
      body = substr($0, idx + length("\"layers\":["))

      n = split(body, parts, /\}[[:space:]]*,[[:space:]]*\{/)
      for (i = 1; i <= n; i++) {
        if (index(parts[i], "\"" want "\"") > 0) {
          last_d = ""
          s = parts[i]
          while (match(s, /"digest"[[:space:]]*:[[:space:]]*"sha256:[a-f0-9]+"/)) {
            last_d = substr(s, RSTART, RLENGTH)
            s = substr(s, RSTART + RLENGTH)
          }
          if (last_d != "") {
            sub(/.*"sha256:/, "sha256:", last_d)
            sub(/".*/, "", last_d)
            print last_d
            exit 0
          }
        }
      }
      exit 1
    }
  ')
  [ -n "$digest" ] || { printf 'error: blob %q not found in manifest\n' "$title" >&2; return 1; }
  curl -fL --retry 3 --retry-delay 2 \
    -H "Authorization: Bearer ${TOKEN}" \
    -o "$dest" \
    "https://ghcr.io/v2/${GHCR_REPO}/blobs/${digest}"
}

echo "[get] downloading ${TARBALL}"
pull_blob "$TARBALL"   "$WORKDIR/$TARBALL"   || exit 1
echo "[get] downloading ${CHECKSUMS}"
pull_blob "$CHECKSUMS" "$WORKDIR/$CHECKSUMS" || exit 1

echo "[get] verifying sha256"
( cd "$WORKDIR" && sha256sum --ignore-missing -c "$CHECKSUMS" >/dev/null ) \
  || { printf 'error: sha256 verification FAILED — aborting install\n' >&2; exit 1; }
echo "[get]   ${TARBALL}: OK"

echo "[get] extracting bundle"
tar -xzf "$WORKDIR/$TARBALL" -C "$WORKDIR"

BUNDLE_DIR="$WORKDIR/certautopilot_${VERSION}_linux_${ARCH}"
if [ ! -x "$BUNDLE_DIR/install.sh" ]; then
  printf 'error: bundle extraction missing install.sh at %s\n' "$BUNDLE_DIR" >&2
  exit 1
fi

echo "[get] handing off to $BUNDLE_DIR/install.sh"
# Release the WORKDIR EXIT trap — after exec the bundle dir must survive
# long enough for install.sh to read templates/, lib/, and web/ from it.
trap - EXIT
# Sentinel that tells install.sh it was invoked from this bootstrap
# (the single legitimate entry point). install.sh refuses to run
# without it, except when an operator explicitly sets the variable
# themselves for internal dev/CI workflows.
export CAP_INVOKED_FROM_BOOTSTRAP=1
exec "$BUNDLE_DIR/install.sh" --version="$VERSION" "${INSTALL_ARGS[@]}"
