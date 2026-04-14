#!/usr/bin/env bash
# CertAutoPilot standalone uninstaller.
#
# Self-contained: does NOT pull anything from GHCR. All uninstall
# steps are local system operations (systemctl, rm, userdel, apt/dnf
# purge). Pair with get.sh for install, update.sh for upgrade.
#
# Three levels:
#
#   (default, no flags)    Stops and removes the service + binary
#                          + nginx drop-in + systemd unit. Data,
#                          secrets, KEK, config, TLS, and MongoDB
#                          are ALL preserved so a subsequent
#                          get.sh re-install picks up where this
#                          host left off.
#
#   --purge                Also wipes /etc/certautopilot (KEK,
#                          secrets, config, TLS), /var/lib/
#                          certautopilot (runtime state, ACME
#                          cache), /var/log/certautopilot, and
#                          removes the certautopilot service user.
#                          MongoDB is left alone.
#
#   --purge-db             Also removes the local MongoDB install
#                          (package + data + mongod.conf + apt/yum
#                          repo files). Implies --purge for
#                          everything else.
#
#   --yes-i-mean-it        Skip the interactive confirmation
#                          prompt for any destructive action.
#                          Required when running non-interactively
#                          (cron, CI, remote bash pipe).
#
# Usage:
#   # Gentle: keep everything that matters, only removes the service.
#   curl -fsSL https://raw.githubusercontent.com/CloudNativeWorks/certautopilot-archive/main/uninstall.sh \
#     | sudo bash
#
#   # Full wipe (KEK gone — NEVER do this on a host with encrypted data):
#   curl -fsSL https://raw.githubusercontent.com/CloudNativeWorks/certautopilot-archive/main/uninstall.sh \
#     | sudo bash -s -- --purge --yes-i-mean-it
#
#   # Nuclear option (also removes local MongoDB):
#   curl -fsSL https://raw.githubusercontent.com/CloudNativeWorks/certautopilot-archive/main/uninstall.sh \
#     | sudo bash -s -- --purge --purge-db --yes-i-mean-it

set -Eeuo pipefail

print_help() {
  cat <<'EOF'
CertAutoPilot standalone uninstaller.

Usage:
  curl -fsSL https://raw.githubusercontent.com/CloudNativeWorks/certautopilot-archive/main/uninstall.sh \
    | sudo bash [-s -- <flags>]

Flags:
  (none)             Remove service + binary + unit + nginx conf. Data
                     and secrets preserved; a subsequent install
                     resumes with the same KEK.

  --purge            Also wipe /etc/certautopilot (incl. KEK, secrets,
                     TLS, config), /var/lib/certautopilot,
                     /var/log/certautopilot, and the service user.
                     If CertAutoPilot also installed the nginx
                     package (marker file present), remove it too.
                     Leave nginx alone when the marker is absent —
                     that means nginx was pre-existing on the host.

  --purge-nginx      Force-remove the nginx package even if we
                     didn't install it originally. Use this only on
                     hosts where CertAutoPilot was the sole nginx
                     consumer. Implies --purge.

  --purge-db         Also remove the local MongoDB package + data +
                     /etc/mongod.conf + apt/yum repo files.
                     Implies --purge for everything else.

  --yes-i-mean-it    Skip all confirmation prompts. REQUIRED when
                     any destructive flag is combined with a piped
                     curl | bash invocation (no tty).

  --help, -h         Print this text and exit.

WARNINGS:
  • --purge deletes /etc/certautopilot/secrets.env which holds the
    KEK. If the host has any envelope-encrypted data (DNS creds,
    ACME account keys, module secrets) in MongoDB, deleting the KEK
    makes ALL of that data UNRECOVERABLE, even if you keep mongo.
  • --purge-db drops the MongoDB package AND /var/lib/mongodb. Any
    database on this host, including ones unrelated to
    CertAutoPilot, will be deleted.

Docs:
  https://github.com/CloudNativeWorks/certautopilot-archive
EOF
}

# ----- flag parsing --------------------------------------------------------
PURGE=0
PURGE_DB=0
PURGE_NGINX=0
FORCE_PURGE_NGINX=0
CONFIRMED=0

while [ $# -gt 0 ]; do
  case "$1" in
    --purge)             PURGE=1 ;;
    --purge-db)          PURGE_DB=1; PURGE=1 ;;
    --purge-nginx)       PURGE_NGINX=1; FORCE_PURGE_NGINX=1; PURGE=1 ;;
    --yes-i-mean-it)     CONFIRMED=1 ;;
    --help|-h)           print_help; exit 0 ;;
    *)
      printf 'unknown flag: %s\n' "$1" >&2
      printf 'run with --help for usage\n' >&2
      exit 2
      ;;
  esac
  shift
done

# When --purge is set, check for the install-time marker file that
# nginx::_install_package writes only when WE actually installed
# nginx. If present, auto-enable nginx purge (user can still opt out
# with an explicit override, but by default a --purge should return
# the host to the state it was in before CertAutoPilot). If the
# marker is missing, nginx was pre-existing and we leave the package
# alone unless the operator explicitly asked with --purge-nginx.
if [ "$PURGE" = "1" ] && [ "$FORCE_PURGE_NGINX" = "0" ]; then
  if [ -f /var/lib/certautopilot/.nginx-installed-by-cap ]; then
    PURGE_NGINX=1
  fi
fi

if [ "$(id -u)" -ne 0 ]; then
  printf 'error: must run as root (use: sudo bash ...)\n' >&2
  exit 2
fi

# ----- helpers -------------------------------------------------------------
if [ -t 1 ]; then
  RST='\033[0m'; RED='\033[31m'; YLW='\033[33m'; BLU='\033[34m'; GRN='\033[32m'
else
  RST=''; RED=''; YLW=''; BLU=''; GRN=''
fi
log::info() { printf '%b[INFO]%b %s\n' "$BLU" "$RST" "$*"; }
log::ok()   { printf '%b[ OK ]%b %s\n' "$GRN" "$RST" "$*"; }
log::warn() { printf '%b[WARN]%b %s\n' "$YLW" "$RST" "$*" >&2; }
log::step() { printf '\n%b==>%b %s\n' "$BLU" "$RST" "$*"; }
die()       { printf '%b[ERR ]%b %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

confirm_destructive() {
  local what=$1
  if [ "$CONFIRMED" = "1" ]; then return 0; fi
  if [ ! -t 0 ]; then
    die "refusing to $what without --yes-i-mean-it (no controlling tty detected)"
  fi
  local ans
  read -r -p "About to $what. Type 'yes' to continue: " ans
  [ "$ans" = "yes" ] || die "aborted by operator"
}

# ----- pre-flight summary --------------------------------------------------
log::step "Uninstall plan"
printf '  binary + service:        %b\n' "${GRN}always removed${RST}"
printf '  nginx drop-in:           %b\n' "${GRN}always removed${RST}"
printf '  journald retention:      %b\n' "${GRN}always removed${RST}"
printf '  /etc/certautopilot:      %b\n' "$([ "$PURGE" = "1" ] && printf "${RED}PURGE${RST}" || printf "${GRN}preserved${RST}")"
printf '  /var/lib/certautopilot:  %b\n' "$([ "$PURGE" = "1" ] && printf "${RED}PURGE${RST}" || printf "${GRN}preserved${RST}")"
printf '  /var/log/certautopilot:  %b\n' "$([ "$PURGE" = "1" ] && printf "${RED}PURGE${RST}" || printf "${GRN}preserved${RST}")"
printf '  certautopilot user/grp:  %b\n' "$([ "$PURGE" = "1" ] && printf "${RED}deleted${RST}" || printf "${GRN}preserved${RST}")"
printf '  nginx package:           %b\n' "$(
  if   [ "$PURGE_NGINX" = "1" ] && [ "$FORCE_PURGE_NGINX" = "1" ]; then printf "${RED}FORCE PURGE (--purge-nginx)${RST}"
  elif [ "$PURGE_NGINX" = "1" ];                                 then printf "${RED}PURGE${RST} (we installed it)"
  elif [ "$PURGE" = "1" ] && [ -f /var/lib/certautopilot/.nginx-installed-by-cap ]; then printf "${YLW}PURGE${RST}"
  elif [ "$PURGE" = "1" ];                                       then printf "${GRN}preserved${RST} (pre-existing, not ours)"
  else                                                                printf "${GRN}preserved${RST}"
  fi
)"
printf '  local MongoDB package:   %b\n' "$([ "$PURGE_DB" = "1" ] && printf "${RED}PURGE${RST}" || printf "${GRN}preserved${RST}")"
printf '  /var/lib/mongodb:        %b\n' "$([ "$PURGE_DB" = "1" ] && printf "${RED}PURGE${RST}" || printf "${GRN}preserved${RST}")"

if [ "$PURGE" = "1" ]; then
  confirm_destructive "PURGE all CertAutoPilot data including the KEK"
fi
if [ "$PURGE_NGINX" = "1" ]; then
  confirm_destructive "REMOVE the nginx package from this host"
fi
if [ "$PURGE_DB" = "1" ]; then
  confirm_destructive "REMOVE local MongoDB (package + all databases on this host)"
fi

# ----- always: stop and remove the service layer ---------------------------
log::step "Stopping service"

# `systemctl cat` is the most reliable "does this unit exist" probe —
# it succeeds iff systemd has a loaded unit file for the name. Using
# `list-unit-files | grep` is fragile because the format varies across
# distros and the regex anchors can drift. We try stop + disable
# loudly (NOT silenced with /dev/null — we want to see failures) so an
# orphan process doesn't sneak past the uninstaller and leave a
# port-in-use error on the next install.
if systemctl cat certautopilot.service >/dev/null 2>&1; then
  if ! systemctl stop certautopilot.service; then
    log::warn "systemctl stop certautopilot.service exited non-zero — continuing"
  fi
  systemctl disable certautopilot.service >/dev/null 2>&1 || true
  log::ok "certautopilot.service stopped + disabled"
fi

# Belt & suspenders: no matter what systemctl said, make sure no
# /usr/local/bin/certautopilot process is still running. This catches:
#   (a) orphaned processes from a previous uninstall that removed the
#       unit file before the process was actually dead;
#   (b) a crash loop where `Restart=on-failure` restarted the service
#       faster than `systemctl stop` could complete;
#   (c) a manually-started binary outside systemd.
# SIGTERM first, wait, SIGKILL if stubborn.
if pgrep -f '/usr/local/bin/certautopilot' >/dev/null 2>&1; then
  log::warn "certautopilot process still running — sending SIGTERM"
  pkill -TERM -f '/usr/local/bin/certautopilot' 2>/dev/null || true
  kill_wait=0
  while [ "$kill_wait" -lt 10 ] && pgrep -f '/usr/local/bin/certautopilot' >/dev/null 2>&1; do
    sleep 1
    kill_wait=$(( kill_wait + 1 ))
  done
  unset kill_wait
  if pgrep -f '/usr/local/bin/certautopilot' >/dev/null 2>&1; then
    log::warn "process still running after 10s — sending SIGKILL"
    pkill -KILL -f '/usr/local/bin/certautopilot' 2>/dev/null || true
    sleep 1
  fi
  if pgrep -f '/usr/local/bin/certautopilot' >/dev/null 2>&1; then
    log::warn "unable to kill certautopilot — check manually: ps -fp \$(pgrep -f /usr/local/bin/certautopilot)"
  else
    log::ok "stale certautopilot process terminated"
  fi
fi

log::step "Stopping + removing backup timer"
if systemctl cat certautopilot-backup.timer >/dev/null 2>&1; then
  systemctl disable --now certautopilot-backup.timer 2>/dev/null || true
fi
rm -f /etc/systemd/system/certautopilot-backup.timer \
      /etc/systemd/system/certautopilot-backup.service \
      /usr/local/bin/certautopilot-backup

log::step "Removing unit + drop-ins"
rm -f /etc/systemd/system/certautopilot.service
systemctl daemon-reload 2>/dev/null || true
systemctl reset-failed certautopilot.service 2>/dev/null || true

log::step "Removing binary + frontend"
rm -f /usr/local/bin/certautopilot
rm -f /usr/local/bin/cap-setup
rm -rf /usr/share/certautopilot/web
# Keep /usr/share/certautopilot/standalone in purge=0 mode so future
# bundled runs still have the helper scripts — but remove it on purge.

log::step "Removing nginx drop-in"
rm -f /etc/nginx/conf.d/certautopilot.conf
rm -f /etc/nginx/conf.d/certautopilot.conf.example
rm -f /etc/nginx/conf.d/certautopilot.conf.broken.*
if systemctl is-active --quiet nginx 2>/dev/null; then
  nginx -t >/dev/null 2>&1 && systemctl reload nginx || \
    log::warn "nginx -t failed after removing our drop-in; check other conf.d files manually"
fi

log::step "Removing journald retention drop-in"
rm -f /etc/systemd/journald.conf.d/10-certautopilot.conf
systemctl restart systemd-journald 2>/dev/null || true

# ----- purge: data + config + user -----------------------------------------
if [ "$PURGE" = "1" ]; then
  log::step "Purging /etc/certautopilot (KEK / secrets / config / TLS)"
  rm -rf /etc/certautopilot

  log::step "Purging /var/lib/certautopilot (runtime state / ACME cache)"
  rm -rf /var/lib/certautopilot

  log::step "Purging /var/log/certautopilot"
  rm -rf /var/log/certautopilot

  log::step "Purging /usr/share/certautopilot"
  rm -rf /usr/share/certautopilot

  log::step "Purging /var/backups/certautopilot"
  rm -rf /var/backups/certautopilot

  log::step "Removing certautopilot system user / group"
  if id certautopilot >/dev/null 2>&1; then
    userdel certautopilot 2>/dev/null || true
  fi
  if getent group certautopilot >/dev/null 2>&1; then
    groupdel certautopilot 2>/dev/null || true
  fi
fi

# ----- purge nginx (only if we installed it or --purge-nginx) -------------
if [ "$PURGE_NGINX" = "1" ]; then
  log::step "Removing nginx package"
  systemctl disable --now nginx 2>/dev/null || true
  if command -v apt-get >/dev/null 2>&1; then
    apt-get purge -y nginx nginx-light nginx-common nginx-core libnginx-mod-http-echo >/dev/null 2>&1 || true
    apt-get autoremove -y >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    pm=$(command -v dnf || command -v yum)
    "$pm" remove -y nginx nginx-core nginx-filesystem >/dev/null 2>&1 || true
  fi
  # Restore the original nginx.conf if we commented its server block
  # on a RHEL-family install.
  if [ -f /etc/nginx/nginx.conf.certautopilot.bak ]; then
    mv -f /etc/nginx/nginx.conf.certautopilot.bak /etc/nginx/nginx.conf 2>/dev/null || true
  fi
  rm -rf /etc/nginx /var/log/nginx /var/cache/nginx
  log::ok "nginx removed"
fi

# ----- purge-db: local MongoDB ---------------------------------------------
if [ "$PURGE_DB" = "1" ]; then
  log::step "Removing MongoDB package + data"
  systemctl disable --now mongod 2>/dev/null || true
  if command -v apt-get >/dev/null 2>&1; then
    apt-get purge -y 'mongodb-org*' 'mongodb-mongosh*' 'mongodb-database-tools*' >/dev/null 2>&1 || true
    apt-get autoremove -y >/dev/null 2>&1 || true
    rm -f /etc/apt/sources.list.d/mongodb-org-*.list
    rm -f /etc/apt/keyrings/mongodb-server-*.gpg
    apt-get update -qq >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    pm=$(command -v dnf || command -v yum)
    "$pm" remove -y 'mongodb-org*' >/dev/null 2>&1 || true
    rm -f /etc/yum.repos.d/mongodb-org-*.repo
  fi
  rm -rf /var/lib/mongodb /var/log/mongodb /var/lib/mongo
  rm -f /etc/mongod.conf /etc/mongod.conf.certautopilot.bak
  log::ok "MongoDB removed"
fi

# ----- firewall rule cleanup (best effort) ---------------------------------
log::step "Removing firewall rule (best effort)"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
  ufw --force delete allow 443/tcp 2>/dev/null || true
  ufw --force delete allow 8181/tcp 2>/dev/null || true
  ufw --force delete allow 8443/tcp 2>/dev/null || true
fi
if systemctl is-active --quiet firewalld 2>/dev/null && command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --permanent --remove-port=443/tcp 2>/dev/null || true
  firewall-cmd --permanent --remove-port=8181/tcp 2>/dev/null || true
  firewall-cmd --permanent --remove-port=8443/tcp 2>/dev/null || true
  firewall-cmd --reload >/dev/null 2>&1 || true
fi

# ----- final residual check ------------------------------------------------
log::step "Residual check"
{
  printf '  /etc/certautopilot:     '
  [ -e /etc/certautopilot ] && printf '%bexists%b\n' "$YLW" "$RST" || printf '%bgone%b\n' "$GRN" "$RST"
  printf '  /var/lib/certautopilot: '
  [ -e /var/lib/certautopilot ] && printf '%bexists%b\n' "$YLW" "$RST" || printf '%bgone%b\n' "$GRN" "$RST"
  printf '  /var/log/certautopilot: '
  [ -e /var/log/certautopilot ] && printf '%bexists%b\n' "$YLW" "$RST" || printf '%bgone%b\n' "$GRN" "$RST"
  printf '  /usr/local/bin/certautopilot: '
  [ -e /usr/local/bin/certautopilot ] && printf '%bexists%b\n' "$YLW" "$RST" || printf '%bgone%b\n' "$GRN" "$RST"
  printf '  /etc/systemd/system/certautopilot.service: '
  [ -e /etc/systemd/system/certautopilot.service ] && printf '%bexists%b\n' "$YLW" "$RST" || printf '%bgone%b\n' "$GRN" "$RST"
  printf '  /etc/nginx/conf.d/certautopilot.conf: '
  [ -e /etc/nginx/conf.d/certautopilot.conf ] && printf '%bexists%b\n' "$YLW" "$RST" || printf '%bgone%b\n' "$GRN" "$RST"
  printf '  certautopilot user: '
  id certautopilot >/dev/null 2>&1 && printf '%bexists%b\n' "$YLW" "$RST" || printf '%bgone%b\n' "$GRN" "$RST"
  if [ "$PURGE_NGINX" = "1" ]; then
    printf '  nginx binary: '
    command -v nginx >/dev/null 2>&1 && printf '%bexists%b\n' "$YLW" "$RST" || printf '%bgone%b\n' "$GRN" "$RST"
    printf '  /etc/nginx: '
    [ -e /etc/nginx ] && printf '%bexists%b\n' "$YLW" "$RST" || printf '%bgone%b\n' "$GRN" "$RST"
  fi
  if [ "$PURGE_DB" = "1" ]; then
    printf '  mongod binary: '
    command -v mongod >/dev/null 2>&1 && printf '%bexists%b\n' "$YLW" "$RST" || printf '%bgone%b\n' "$GRN" "$RST"
    printf '  /var/lib/mongodb: '
    [ -e /var/lib/mongodb ] && printf '%bexists%b\n' "$YLW" "$RST" || printf '%bgone%b\n' "$GRN" "$RST"
  fi
}

log::ok "uninstall complete"
if [ "$PURGE" = "0" ]; then
  printf '\n'
  printf '  Data preserved. To reinstall on this host:\n'
  printf '    curl -fsSL https://raw.githubusercontent.com/CloudNativeWorks/certautopilot-archive/main/get.sh \\\n'
  printf '      | sudo bash -s -- --version=<pinned> --mongo=local\n'
fi
