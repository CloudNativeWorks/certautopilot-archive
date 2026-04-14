# certautopilot-archive

Public bootstrap shim for the [CertAutoPilot](https://github.com/CloudNativeWorks/certautopilot)
standalone installer. The main project repo stays private; this tiny repo
and the companion public OCI package at `ghcr.io/cloudnativeworks/standalone/certautopilot`
are the only external entry points for bare-metal deployment.

## What's here

A single script — `get.sh` — that:

1. Requests an anonymous GHCR pull token for
   `ghcr.io/cloudnativeworks/standalone/certautopilot`
2. Fetches the OCI manifest for the pinned version
3. Parses the layer digests for the Linux/amd64 tarball and checksums file
4. Downloads both, verifies the sha256, extracts the bundle
5. Executes the bundled `install.sh` with every extra CLI flag forwarded

No module-manager dependency. No `oras`, no `jq`, no `docker`. Just
`curl`, `tar`, `awk`, `sha256sum`, and `bash` — all present out of the
box on every supported distro (RHEL 9+, Oracle Linux 9+, Rocky 9+,
AlmaLinux 9+, Debian 12+, Ubuntu 22.04+).

## Install CertAutoPilot in one command

```bash
curl -fsSL https://raw.githubusercontent.com/CloudNativeWorks/certautopilot-archive/main/get.sh \
  | sudo bash -s -- --version=1.3.12 --mongo=local
```

`--version=<pinned>` is required. There is no `latest` auto-resolve —
every install pins an explicit version by design.

### External MongoDB

```bash
curl -fsSL https://raw.githubusercontent.com/CloudNativeWorks/certautopilot-archive/main/get.sh \
  | sudo bash -s -- \
      --version=1.3.12 \
      --mongo=external \
      --mongo-uri="mongodb://user:pass@db.internal:27017/?authSource=admin"
```

### User-provided TLS

```bash
curl -fsSL https://raw.githubusercontent.com/CloudNativeWorks/certautopilot-archive/main/get.sh \
  | sudo bash -s -- \
      --version=1.3.12 \
      --mongo=local \
      --tls=provided \
      --cert=/etc/ssl/certs/cert.example.com.pem \
      --key=/etc/ssl/private/cert.example.com.key
```

### Custom ports

```bash
curl -fsSL https://raw.githubusercontent.com/CloudNativeWorks/certautopilot-archive/main/get.sh \
  | sudo bash -s -- \
      --version=1.3.12 \
      --mongo=local \
      --port=8443 \
      --backend-port=18181
```

Every flag after `--version=` is forwarded verbatim to the bundled
`install.sh`. The full flag list is documented in
[`deploy/standalone/README.md`](https://ghcr.io/cloudnativeworks/standalone/certautopilot)
inside the release bundle.

## Installation topology

```
Internet
   │
   │ :443 HTTPS  (TLS terminated at nginx)
   ▼
nginx (systemd unit, distro package)
   │
   │ /api/*       /healthz /readyz /metrics
   │ /            /assets/ (React SPA, long-cache)
   ▼
127.0.0.1:18181  certautopilot (systemd unit, loopback plaintext)
   │
   ▼
MongoDB 7.0 (local SCRAM auth, or external URI)
```

- **HTTPS-only**: the backend has no public port. nginx terminates TLS
  with a 10-year self-signed cert generated at install time (replace
  with your own via `--tls=provided`).
- **Local MongoDB**: always provisioned with SCRAM authorization and a
  scoped application user. The root password is saved to
  `/etc/certautopilot/mongo-root.env` (mode 0600) for disaster recovery.
- **Hardened systemd unit**: `ProtectSystem=strict`, `NoNewPrivileges`,
  `MemoryDenyWriteExecute`, narrow `ReadWritePaths`, loopback-only
  listener.

## Rerun / upgrade safety

The installer is idempotent. On a rerun:

- **KEK / JWT secret / API key pepper** — preserved byte-for-byte.
  Regenerating the KEK would make envelope-encrypted data unrecoverable.
- **MongoDB `capApp` password** — fast-path skip when auth is already
  on and `secrets.env` holds a working URI. No unnecessary rotation.
- **`config.yaml`** — preserved. A fresh copy of the defaults is
  dropped next to it as `config.yaml.example` for diff + merge.
- **`/etc/nginx/conf.d/certautopilot.conf`** — preserved. Fresh copy
  next to it as `certautopilot.conf.example`.
- **TLS cert + key** — preserved if both files already exist.

To force a clean re-render of any managed file, delete it before
rerunning `get.sh`.

## Upgrade

Re-running `get.sh` with a newer `--version=` on an already-installed
host performs an in-place upgrade: binary and frontend assets are
replaced atomically, everything else is preserved.

```bash
curl -fsSL https://raw.githubusercontent.com/CloudNativeWorks/certautopilot-archive/main/get.sh \
  | sudo bash -s -- --version=1.3.13 --mongo=local
```

## Uninstall

The full uninstaller ships inside the bundle (not this bootstrap). Pull
it once via `oras` or another tarball download, then:

```bash
sudo ./uninstall.sh             # stop + remove binary/unit, keep data
sudo ./uninstall.sh --purge     # also wipe config / state / logs / user
sudo ./uninstall.sh --purge --purge-db --yes-i-mean-it   # also drop local MongoDB
```

## Troubleshooting

```bash
systemctl status certautopilot nginx
journalctl -u certautopilot -f
journalctl -u nginx -f
curl -k https://127.0.0.1/readyz             # via nginx
curl    http://127.0.0.1:18181/readyz        # direct to backend
```

## License

See the main CertAutoPilot repo for licensing. This bootstrap script
is published under the same terms.
