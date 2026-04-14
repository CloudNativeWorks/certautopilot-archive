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
