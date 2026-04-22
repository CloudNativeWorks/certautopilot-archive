# certautopilot-archive

Public bootstrap shims for the
[CertAutoPilot](https://github.com/CloudNativeWorks/certautopilot)
standalone installer. The main project repo stays private; this tiny
repo and the companion public OCI package at
`ghcr.io/cloudnativeworks/standalone/certautopilot` are the only
external entry points for bare-metal deployment.

## What's here

Three self-contained scripts, each exactly one command to run:

| Script | Purpose |
|---|---|
| [`get.sh`](./get.sh) | First-time install. Pulls the pinned tarball from GHCR, verifies sha256, extracts, runs the bundled `install.sh`. |
| [`update.sh`](./update.sh) | In-place upgrade to a newer pinned version. Atomic binary + frontend swap; config, secrets, KEK, TLS, Mongo data all preserved. |
| [`uninstall.sh`](./uninstall.sh) | Remove the service (three levels from gentle to full purge). Self-contained — does NOT pull anything from GHCR. |

No runtime dependencies. No `oras`, no `jq`, no `docker`. Just `curl`,
`tar`, `awk`, `sha256sum`, and `bash` — all present out of the box on
every supported distro (RHEL 9+, Oracle Linux 9+, Rocky 9+,
AlmaLinux 9+, Debian 12+, Ubuntu 22.04+).

---

## Install — `get.sh`

### Simplest case

```bash
curl -fsSL https://raw.githubusercontent.com/CloudNativeWorks/certautopilot-archive/main/get.sh \
  | sudo bash -s -- --version=1.3.16 --mongo=local
```

`--version=<pinned>` is required. There is no `latest` auto-resolve —
every install pins an explicit version by design.

> **Security:** `get.sh` needs root (writes `/etc`, creates the service
> user, installs systemd units). The CertAutoPilot backend then runs
> as a dedicated non-root system user (`certautopilot`, nologin shell,
> no home directory) under a hardened systemd unit
> (`NoNewPrivileges`, `ProtectSystem=strict`, `LimitCORE=0`). Root is
> never used at runtime.
>
> `install.sh` — the script inside the tarball — refuses to run unless
> invoked via `get.sh` (the sentinel `CAP_INVOKED_FROM_BOOTSTRAP=1` is
> exported by `get.sh` just before exec). This keeps the pinned-version
> contract and the SHA256 integrity check as the only supported path.

### External MongoDB

```bash
curl -fsSL https://raw.githubusercontent.com/CloudNativeWorks/certautopilot-archive/main/get.sh \
  | sudo bash -s -- \
      --version=1.3.16 \
      --mongo=external \
      --mongo-uri="mongodb://user:pass@db.internal:27017"
```

The installer parses the URI into individual `host` / `port` /
`username` / `password` fields — the full URI is never persisted,
because Viper's `AutomaticEnv` can't bind a unified `database.uri`
field (no `SetDefault` for it in the backend) so individual fields
are the only shape the backend actually reads.

### Multi-VM deployment (2+ hosts, shared external MongoDB)

Running two or more CertAutoPilot hosts against a single external
MongoDB is supported, but each host generates its own random KEK /
JWT / API-key pepper on first install. Every host after the first
MUST adopt the first host's `/etc/certautopilot/secrets.env` via the
`--secrets-from=<path>` flag — otherwise the new host cannot decrypt
any envelope-encrypted field (ACME private keys, DNS credentials,
module secrets, license API key, …) the other hosts already wrote.

```bash
# On cap-a (first host):
curl -fsSL https://raw.githubusercontent.com/CloudNativeWorks/certautopilot-archive/main/get.sh \
  | sudo bash -s -- \
      --version=1.3.22 \
      --mongo=external \
      --mongo-uri="mongodb://user:pass@db.internal:27017"

# Copy secrets.env from cap-a to cap-b (use SSH; treat this file as a
# root-level credential — whoever holds it can decrypt everything).
scp cap-a:/etc/certautopilot/secrets.env /tmp/cap-shared.env
scp /tmp/cap-shared.env cap-b:/tmp/
shred -u /tmp/cap-shared.env

# On cap-b (and every additional host):
curl -fsSL https://raw.githubusercontent.com/CloudNativeWorks/certautopilot-archive/main/get.sh \
  | sudo bash -s -- \
      --version=1.3.22 \
      --mongo=external \
      --mongo-uri="mongodb://user:pass@db.internal:27017" \
      --secrets-from=/tmp/cap-shared.env

sudo shred -u /tmp/cap-shared.env
```

> **secrets.env holds the KEK.** Transfer only over SSH, install with
> mode `0600`, and shred temporary copies immediately. For production
> consider an ephemeral shared-secret channel (Vault, 1Password shared
> vault, SealedSecrets export) instead of `scp`.

**Run the initial admin wizard on exactly ONE host.** The backend
guards setup with a cluster-wide `$setOnInsert` flag, so concurrent
wizard submissions from two hosts still produce exactly one admin +
one default project — the loser receives
`400 setup already completed`. Every host beyond the first sees the
flag already set and redirects `/setup` to the login page.

Full procedure (TLS options, setup wizard, backups, upgrade order,
troubleshooting) is documented at
<https://certautopilot.com/docs/deployment/multi-vm.html>.

### PKCS#11 provider (HSM-backed KEK)

CertAutoPilot can wrap KEKs with a key stored in an HSM instead of
raw bytes in `secrets.env`. The vendor SDK (SoftHSM2, Thales Luna,
AWS CloudHSM, Fortanix DSM, …) must be installed separately — each
vendor has its own install procedure; see
<https://certautopilot.com/docs/encryption/pkcs11-vendors.html>.
`get.sh` then installs CertAutoPilot on top of that in one command.

Pick one of the two PIN ingress modes:

```bash
# Inline PIN (quickest; PIN visible in /proc/<pid>/cmdline during install
# only, persists afterward only in /etc/certautopilot/secrets.env mode 0600):
curl -fsSL https://raw.githubusercontent.com/CloudNativeWorks/certautopilot-archive/main/get.sh \
  | sudo bash -s -- \
      --version=1.3.22 --mongo=local \
      --kek-provider=pkcs11 \
      --pkcs11-module=/usr/lib/softhsm/libsofthsm2.so \
      --pkcs11-token-label=certautopilot-prod \
      --pkcs11-pin='<HSM_USER_PIN>'
```

```bash
# PIN from file (production-grade; the PIN never appears in argv or
# shell history):
umask 077
printf '%s' "$HSM_PIN" > /tmp/cap-pin
curl -fsSL https://raw.githubusercontent.com/CloudNativeWorks/certautopilot-archive/main/get.sh \
  | sudo bash -s -- \
      --version=1.3.22 --mongo=local \
      --kek-provider=pkcs11 \
      --pkcs11-module=/opt/thales/lib/libCryptoki2_64.so \
      --pkcs11-token-label=certautopilot \
      --pkcs11-pin-file=/tmp/cap-pin
shred -u /tmp/cap-pin
```

After install, the PIN lives only in `/etc/certautopilot/secrets.env`
(mode 0600, owned by the `certautopilot` service user). Systemd
loads it via `EnvironmentFile=` on every service start, so reboots
and `systemctl restart` pick it up automatically — the PIN does not
need to be re-supplied.

### User-provided TLS

```bash
curl -fsSL https://raw.githubusercontent.com/CloudNativeWorks/certautopilot-archive/main/get.sh \
  | sudo bash -s -- \
      --version=1.3.16 \
      --mongo=local \
      --tls=provided \
      --cert=/etc/ssl/certs/cert.example.com.pem \
      --key=/etc/ssl/private/cert.example.com.key
```

### Custom ports

```bash
curl -fsSL https://raw.githubusercontent.com/CloudNativeWorks/certautopilot-archive/main/get.sh \
  | sudo bash -s -- \
      --version=1.3.16 \
      --mongo=local \
      --port=8443 \
      --backend-port=18181
```

Every flag after `--version=` is forwarded verbatim to the bundled
`install.sh`. Run `get.sh --help` for the full flag list.

---

## Operator helpers — what `get.sh` / `update.sh` install alongside the backend

Every install/update drops the backend binary and — when the operator
opts in — a small backup helper alongside it.

| Path | Purpose |
|---|---|
| `/usr/local/bin/certautopilot` | The backend binary (what `certautopilot.service` runs). All KEK lifecycle commands live under `certautopilot kek <subcommand>`. |
| `/usr/local/bin/certautopilot-backup` | mongodump wrapper the `certautopilot-backup.timer` fires daily. Installed only when the operator passes `--enable-backup` **and** `--mongo=local`. External-mongo deployments own their own backup stack; local-mongo installs without `--enable-backup` stay backup-free so operators with their own cron/restic/Ansible orchestration aren't doubled up. |

`update.sh` refreshes both on every version bump and preserves the
operator's prior `--enable-backup` choice — if the timer was enabled
before, it stays enabled after upgrade; if it was absent, upgrade
doesn't silently install one.

### KEK rotation on a single host

```bash
# 1. Add the new key material to secrets.env (env provider only).
printf '\nCERTAUTOPILOT_ENCRYPTION_ENV_KEK_V2=%s\n' "$(openssl rand -hex 32)" \
  | sudo tee -a /etc/certautopilot/secrets.env >/dev/null
sudo systemctl restart certautopilot

# 2. Verify fleet has loaded V2, then rotate. The keystore in MongoDB
#    is authoritative for the active version — no per-host config bump.
sudo certautopilot kek verify --target=2
sudo certautopilot kek rotate --from-version=1 --to-version=2
sudo certautopilot kek status    # poll until completed

# 3. Restart every node so it picks up the new active version from
#    the keystore.
sudo systemctl restart certautopilot
```

For a multi-VM deployment, loop step 1 over every host before step 2,
then loop step 3 after rotation completes. Full procedure (including
PKCS#11 and K8s paths) at
<https://certautopilot.com/docs/encryption/kek-rotation.html>.

---

## Upgrade — `update.sh`

In-place upgrade to a newer pinned version:

```bash
curl -fsSL https://raw.githubusercontent.com/CloudNativeWorks/certautopilot-archive/main/update.sh \
  | sudo bash -s -- --version=1.3.17
```

What it does:
- pulls the new tarball from GHCR
- verifies the sha256
- extracts the bundle
- stops `certautopilot.service`
- atomically replaces `/usr/local/bin/certautopilot`
- refreshes `/usr/share/certautopilot/web` (frontend assets)
- starts `certautopilot.service`
- probes backend loopback + nginx `/readyz`

Everything else is preserved byte-for-byte:
- `/etc/certautopilot/secrets.env` (KEK / JWT / pepper / Mongo creds)
- `/etc/certautopilot/config.yaml`
- `/etc/certautopilot/tls/`
- `/etc/certautopilot/mongo-root.env`
- `/etc/nginx/conf.d/certautopilot.conf`
- MongoDB data and users

> **If you need to change install-time flags** (ports, Mongo mode, TLS
> mode, `--bind-host`, etc.), use `get.sh` instead. The bundled
> `install.sh` is idempotent: it re-renders anything the new flags
> affect while still preserving secrets.

---

## Uninstall — `uninstall.sh`

Three levels, pick the gentlest one that meets your need.

### Level 1 — Gentle (data preserved, reinstallable)

```bash
curl -fsSL https://raw.githubusercontent.com/CloudNativeWorks/certautopilot-archive/main/uninstall.sh \
  | sudo bash
```

Stops the service and removes the binary, systemd unit, nginx
drop-in, logrotate config, and frontend assets. Everything under
`/etc/certautopilot` (including the KEK) and `/var/lib/certautopilot`
stays on disk, so a later `get.sh` re-install on the same host picks
up exactly where this host left off — same KEK, same Mongo users,
same TLS cert.

### Level 2 — Purge (data wiped, KEK gone)

```bash
curl -fsSL https://raw.githubusercontent.com/CloudNativeWorks/certautopilot-archive/main/uninstall.sh \
  | sudo bash -s -- --purge --yes-i-mean-it
```

Adds: wipe `/etc/certautopilot`, `/var/lib/certautopilot`,
`/var/log/certautopilot`, `/usr/share/certautopilot`, and the
`certautopilot` service user. **MongoDB data is NOT touched** — the
database and its users stay in place.

> ⚠️ **This deletes the KEK.** If this host holds ANY envelope-
> encrypted data in MongoDB (ACME account keys, DNS provider
> credentials, module secrets, any encrypted field), the `--purge`
> run makes ALL of it permanently unrecoverable, even if you keep
> MongoDB. Only use `--purge` when you're sure either (a) there is
> no encrypted data on this host, or (b) you have restored the KEK
> from a backup elsewhere.

> **Multi-VM note:** Every host in a multi-VM deployment holds the
> same KEK in its local `secrets.env`. `--purge` on one host deletes
> the file only there — the surviving hosts still hold a working
> copy, so the cluster's encrypted data remains decryptable and new
> hosts can be bootstrapped with `--secrets-from` pointing at any
> surviving host's file. But `--purge`'ing EVERY host without first
> exporting a copy of `secrets.env` elsewhere is equivalent to losing
> the KEK entirely — there is no recovery path.

### Level 3 — Purge + drop local MongoDB

```bash
curl -fsSL https://raw.githubusercontent.com/CloudNativeWorks/certautopilot-archive/main/uninstall.sh \
  | sudo bash -s -- --purge --purge-db --yes-i-mean-it
```

Adds: remove the `mongodb-org*` packages, `/var/lib/mongodb`,
`/etc/mongod.conf`, apt/yum repo files. This is the cleanest possible
state for a fresh reinstall on a host that was only used for
CertAutoPilot. **Removes every database on this host**, not just the
`certautopilot` one — don't use it on shared MongoDB hosts.

### Non-interactive context

When running via `curl | bash`, there is no controlling tty and the
script refuses to perform destructive operations without
`--yes-i-mean-it`. This is intentional — a fat-finger `--purge` on a
hot-key copy-paste without the confirmation flag is a safe no-op.

---

## Installation topology

```
Internet
   │
   │ :443 HTTPS  (TLS terminated at nginx with a 10-year self-signed cert,
   ▼                or user-provided cert via --tls=provided)
nginx (systemd unit, distro package)
   │
   │ /api/*, /healthz, /readyz, /metrics     static SPA assets
   ▼                                         (/usr/share/.../web)
127.0.0.1:18181  certautopilot (systemd unit, loopback plaintext, hardened)
   │
   ▼
MongoDB 7.0/8.0 (local SCRAM auth, or external URI parsed into fields)
```

- **HTTPS-only**: the backend has no public port. nginx terminates
  TLS. The firewall rule only opens the HTTPS port.
- **MongoDB**: local mode always provisions SCRAM authorization with
  a random `capRoot` (admin) + a scoped `capApp` user. Root password
  is saved to `/etc/certautopilot/mongo-root.env` (mode 0600) for
  disaster recovery. External mode trusts whatever URI you provide.
- **Hardened systemd unit**: `ProtectSystem=strict`,
  `NoNewPrivileges`, `MemoryDenyWriteExecute`, narrow
  `ReadWritePaths`, loopback-only listener.

## Rerun / upgrade safety

The installer is idempotent. On a rerun with `get.sh`:

- **KEK / JWT secret / API key pepper** — preserved byte-for-byte.
- **MongoDB `capApp` password** — fast-path skip when auth is already
  on and `secrets.env` holds working credentials.
- **`config.yaml`** — preserved. Fresh defaults dropped next to it
  as `config.yaml.example` for diff + merge.
- **`/etc/nginx/conf.d/certautopilot.conf`** — preserved unless
  `nginx -t` says it's broken, in which case it's backed up to
  `.broken.<ts>` and re-rendered from template (self-healing).
- **TLS cert + key** — preserved if both files already exist.

Force a clean re-render by deleting the relevant file before
rerunning `get.sh`.

## Troubleshooting

```bash
systemctl status certautopilot nginx
journalctl -u certautopilot -f
journalctl -u nginx -f
curl -k https://127.0.0.1/readyz             # via nginx
curl    http://127.0.0.1:18181/readyz        # direct to backend
```

## License

Published under the same terms as the main CertAutoPilot repo.
