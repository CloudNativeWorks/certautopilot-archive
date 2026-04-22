#!/usr/bin/env bash
# CertAutoPilot standalone update.
#
# Pulls the pinned release tarball from the public GHCR OCI package,
# verifies its sha256 checksum, extracts the bundle, and hands off to
# the bundled upgrade.sh. An update is an in-place binary + frontend
# refresh — config.yaml, secrets.env, TLS material, nginx config, and
# MongoDB data are all preserved. If you need to change install-time
# flags (ports, Mongo mode, TLS mode, etc.) use get.sh instead; the
# bundled install.sh re-renders anything the new flags affect while
# still preserving secrets.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/CloudNativeWorks/certautopilot-archive/main/update.sh \
#     | sudo bash -s -- --version=1.3.16
#
# Required environment: root + curl + tar + awk + sha256sum.

set -Eeuo pipefail

GHCR_REPO=${GHCR_REPO:-cloudnativeworks/standalone/certautopilot}

print_help() {
  cat <<'EOF'
CertAutoPilot standalone update.

Usage:
  curl -fsSL https://raw.githubusercontent.com/CloudNativeWorks/certautopilot-archive/main/update.sh \
    | sudo bash -s -- --version=<pinned>

Required:
  --version=<pinned>    Pinned release to upgrade to (e.g. 1.3.17).
                        No "latest" auto-resolve.

What it does:
  • Pulls the pinned tarball from GHCR (same package as get.sh).
  • Verifies the sha256 checksum.
  • Extracts the bundle to a tempdir.
  • Executes the bundle's upgrade.sh which:
      - stops certautopilot.service
      - atomically replaces /usr/local/bin/certautopilot
      - refreshes /usr/share/certautopilot/web
      - starts certautopilot.service
      - probes backend + nginx /readyz

Scope — what update.sh does NOT do:
  update.sh is a binary + frontend refresh only. Topology and config
  flags (--mongo, --mongo-uri, --tls, --cert, --key, --port,
  --bind-host, --extra-hostnames, --kek-provider, --enable-backup, …)
  are NOT honored here — pass those to get.sh if you need to change
  anything beyond the version. The bundled install.sh is idempotent:
  it re-renders just what the new flags affect while preserving every
  secret on disk.

Preserved across update:
  • /etc/certautopilot/secrets.env (KEK / JWT / pepper / Mongo creds)
  • /etc/certautopilot/config.yaml
  • /etc/certautopilot/tls/
  • /etc/certautopilot/mongo-root.env
  • /etc/nginx/conf.d/certautopilot.conf
  • MongoDB data and users
  • systemd unit (unless the template changed)

Docs:
  https://github.com/CloudNativeWorks/certautopilot-archive
EOF
}

VERSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version=*) VERSION=${1#*=} ;;
    --version)   VERSION=${2:-}; shift ;;
    --help|-h)   print_help; exit 0 ;;
    *)
      printf 'unknown flag: %s\n' "$1" >&2
      printf 'run with --help for usage\n' >&2
      exit 2
      ;;
  esac
  shift
done

if [ -z "$VERSION" ]; then
  printf 'error: --version=<pinned> is required (example: --version=1.3.16)\n' >&2
  printf 'no latest auto-resolve — every update pins an explicit version.\n' >&2
  exit 2
fi

if [ "$(id -u)" -ne 0 ]; then
  printf 'error: must run as root (use: sudo bash -s -- --version=%s)\n' "$VERSION" >&2
  exit 2
fi

for cmd in curl tar awk sha256sum sed grep; do
  command -v "$cmd" >/dev/null 2>&1 || { printf 'error: required command not found: %s\n' "$cmd" >&2; exit 2; }
done

# Sanity check: there must be an existing install to upgrade.
if [ ! -x /usr/local/bin/certautopilot ]; then
  printf 'error: /usr/local/bin/certautopilot not found — use get.sh for a fresh install\n' >&2
  exit 2
fi

ARCH_RAW=$(uname -m)
case "$ARCH_RAW" in
  x86_64|amd64) ARCH=amd64 ;;
  *)
    printf 'error: unsupported architecture %s — only linux_amd64 is published\n' "$ARCH_RAW" >&2
    exit 2
    ;;
esac

TARBALL="certautopilot_${VERSION}_linux_${ARCH}.tar.gz"
CHECKSUMS="certautopilot_${VERSION}_checksums.txt"

echo "[update] requesting anonymous GHCR pull token"
TOKEN_JSON=$(curl -fsSL "https://ghcr.io/token?scope=repository:${GHCR_REPO}:pull&service=ghcr.io") \
  || { printf 'error: failed to obtain GHCR token — is the package public?\n' >&2; exit 1; }

TOKEN=$(printf '%s' "$TOKEN_JSON" | grep -oE '"token":"[^"]+"' | head -n1 | sed 's/"token":"\(.*\)"/\1/')
if [ -z "$TOKEN" ]; then
  TOKEN=$(printf '%s' "$TOKEN_JSON" | grep -oE '"access_token":"[^"]+"' | head -n1 | sed 's/"access_token":"\(.*\)"/\1/')
fi
[ -n "$TOKEN" ] || { printf 'error: could not parse GHCR token\n' >&2; exit 1; }

echo "[update] fetching manifest ${GHCR_REPO}:${VERSION}"
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
# then downloads that layer's blob to <dest>. See get.sh for the full
# rationale behind the awk parser — short version: mongo manifests
# nest the title inside annotations:{} so naive regex can't reach the
# digest, and parts[1] carries the config.digest which we skip by
# taking the LAST digest per layer object.
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

echo "[update] downloading ${TARBALL}"
pull_blob "$TARBALL"   "$WORKDIR/$TARBALL"   || exit 1
echo "[update] downloading ${CHECKSUMS}"
pull_blob "$CHECKSUMS" "$WORKDIR/$CHECKSUMS" || exit 1

echo "[update] verifying sha256"
( cd "$WORKDIR" && sha256sum --ignore-missing -c "$CHECKSUMS" >/dev/null ) \
  || { printf 'error: sha256 verification FAILED — aborting update\n' >&2; exit 1; }
echo "[update]   ${TARBALL}: OK"

echo "[update] extracting bundle"
tar -xzf "$WORKDIR/$TARBALL" -C "$WORKDIR"

BUNDLE_DIR="$WORKDIR/certautopilot_${VERSION}_linux_${ARCH}"
if [ ! -x "$BUNDLE_DIR/upgrade.sh" ]; then
  printf 'error: bundle extraction missing upgrade.sh at %s\n' "$BUNDLE_DIR" >&2
  exit 1
fi

echo "[update] handing off to $BUNDLE_DIR/upgrade.sh"
trap - EXIT
exec "$BUNDLE_DIR/upgrade.sh"
