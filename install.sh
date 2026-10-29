#!/usr/bin/env bash
# NX Panel installer and updater. Re-run it to update in place.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/nx-panel/panel/main/install.sh)
set -euo pipefail

PANEL_REPO="nx-panel/panel"
NODE_REPO="nx-panel/node"
INSTALL_DIR="/opt/nx-panel"   # binary + config.json
STATE_DIR="/var/opt/nx-panel"       # database, node binaries, themes, backups
SERVICE="nx-panel"
UNIT="/etc/systemd/system/${SERVICE}.service"

PANEL_VERSION=""    # empty = the latest release
NODE_VERSION=""     # empty = the latest release
USE_POSTGRES=0
DO_UNINSTALL=0
PG_DB="nx"
PG_USER="nx"

die() {
  echo "error: $*" >&2
  # A failure after an install made under the old name was moved puts it back.
  [[ "${TRANSFERRED:-0}" -eq 0 ]] || restore_transfer
  exit 1
}
panel_version() { "${INSTALL_DIR}/nx-panel" version 2>/dev/null | awk '{print $2}'; }
nx_panel() { "${INSTALL_DIR}/nx-panel" "$@"; }
say() { printf '\033[1;35m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warn\033[0m %s\n' "$*" >&2; }

usage() {
  cat >&2 <<EOF
NX Panel installer

  install.sh [--postgres] [--version vX.Y.Z] [--node-version vX.Y.Z]
  install.sh --uninstall

  --postgres          install and configure PostgreSQL instead of SQLite
  --version TAG       install a specific panel release instead of the latest
  --node-version TAG  stage a specific node release instead of the latest
  --uninstall         stop and remove the panel (the database is kept)

Re-running the installer on an existing install performs an update.
EOF
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --postgres) USE_POSTGRES=1; shift ;;
    --version) PANEL_VERSION="${2:-}"; [[ -n "$PANEL_VERSION" ]] || usage; shift 2 ;;
    --node-version) NODE_VERSION="${2:-}"; [[ -n "$NODE_VERSION" ]] || usage; shift 2 ;;
    --uninstall) DO_UNINSTALL=1; shift ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done

[[ $EUID -eq 0 ]] || die "please run as root"
command -v systemctl >/dev/null || die "this installer needs systemd; use the Docker install instead"
command -v curl >/dev/null || die "curl is required"
command -v tar >/dev/null || die "tar is required"

# --- platform -----------------------------------------------------------------

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "linux-amd64" ;;
    aarch64|arm64) echo "linux-arm64" ;;
    armv7l|armv7) echo "linux-armv7" ;;
    armv6l|armv6) echo "linux-armv6" ;;
    i386|i686) echo "linux-386" ;;
    s390x) echo "linux-s390x" ;;
    riscv64) echo "linux-riscv64" ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}
ARCH="$(detect_arch)"

[[ -n "$PANEL_VERSION" && "$PANEL_VERSION" != v* ]] && PANEL_VERSION="v${PANEL_VERSION}"
[[ -n "$NODE_VERSION" && "$NODE_VERSION" != v* ]] && NODE_VERSION="v${NODE_VERSION}"

# NX_DOWNLOAD_BASE points at a flat mirror instead of GitHub.
asset_url() {
  local repo="$1" version="$2" name="$3"
  if [[ -n "${NX_DOWNLOAD_BASE:-}" ]]; then
    echo "${NX_DOWNLOAD_BASE%/}/${name}"
  elif [[ -n "$version" ]]; then
    echo "https://github.com/${repo}/releases/download/${version}/${name}"
  else
    echo "https://github.com/${repo}/releases/latest/download/${name}"
  fi
}

# --- uninstall ----------------------------------------------------------------

if [[ $DO_UNINSTALL -eq 1 ]]; then
  say "stopping ${SERVICE}"
  systemctl disable --now "$SERVICE" 2>/dev/null || true
  rm -f "$UNIT" /usr/local/bin/nx-panel
  systemctl daemon-reload
  rm -rf "$INSTALL_DIR"
  echo
  echo "NX is removed. The database and the backups under ${STATE_DIR}"
  echo "were left alone. Delete them yourself once you are sure — and take a copy"
  echo "of ${STATE_DIR}/backups first if this server is going away:"
  echo "  rm -rf ${STATE_DIR}"
  exit 0
fi

# --- postgres -----------------------------------------------------------------

# Everything to stderr: setup_postgres returns the DSN on stdout.
pkg_install() {
  if command -v apt-get >/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >&2
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >&2
  elif command -v dnf >/dev/null; then
    dnf install -y -q "$@" >&2
  elif command -v yum >/dev/null; then
    yum install -y -q "$@" >&2
  elif command -v pacman >/dev/null; then
    pacman -Sy --noconfirm "$@" >&2
  else
    die "no supported package manager found; install PostgreSQL yourself and re-run without --postgres"
  fi
}

# Avoids `tr < /dev/urandom`, whose SIGPIPE trips `set -o pipefail`.
rand_pass() {
  if command -v openssl >/dev/null; then
    openssl rand -hex 16
  else
    head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

# Idempotent: an update must not rotate the password under a working panel.
setup_postgres() {
  if ! command -v psql >/dev/null; then
    say "installing PostgreSQL" >&2
    if command -v apt-get >/dev/null; then
      pkg_install postgresql postgresql-contrib
    else
      pkg_install postgresql-server postgresql || pkg_install postgresql
      # RHEL-family packages ship an uninitialised cluster.
      if [[ -x /usr/bin/postgresql-setup ]] && [[ ! -f /var/lib/pgsql/data/PG_VERSION ]]; then
        /usr/bin/postgresql-setup --initdb >/dev/null 2>&1 || true
      fi
    fi
  fi
  systemctl enable --now postgresql >/dev/null 2>&1 ||
    systemctl enable --now postgresql.service >/dev/null 2>&1 ||
    die "could not start PostgreSQL"

  local pass
  pass="$(rand_pass)"

  say "configuring the ${PG_DB} database" >&2
  su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='${PG_USER}'\"" | grep -q 1 ||
    su - postgres -c "psql -q -c \"CREATE ROLE ${PG_USER} LOGIN PASSWORD '${pass}'\"" >/dev/null
  su - postgres -c "psql -q -c \"ALTER ROLE ${PG_USER} PASSWORD '${pass}'\"" >/dev/null
  su - postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='${PG_DB}'\"" | grep -q 1 ||
    su - postgres -c "createdb -O ${PG_USER} ${PG_DB}" >/dev/null

  # Some distributions default loopback TCP to peer auth, which no password
  # can satisfy.
  local hba
  hba="$(su - postgres -c 'psql -tAc "SHOW hba_file"' | tr -d '[:space:]')"
  if [[ -f "$hba" ]] && ! grep -qE "^host +${PG_DB} +${PG_USER} +127\.0\.0\.1/32" "$hba"; then
    printf 'host %s %s 127.0.0.1/32 scram-sha-256\n' "$PG_DB" "$PG_USER" >> "$hba"
    systemctl reload postgresql >/dev/null 2>&1 || systemctl restart postgresql >/dev/null 2>&1 || true
  fi

  echo "host=127.0.0.1 port=5432 user=${PG_USER} password=${pass} dbname=${PG_DB} sslmode=disable"
}

# --- listen port --------------------------------------------------------------

# Below the ephemeral range: above it, a restart can find its number held by an
# outbound socket and fail to bind.
ephemeral_low() {
  local low=""
  if [[ -r /proc/sys/net/ipv4/ip_local_port_range ]]; then
    low="$(awk '{print $1}' /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null || true)"
  fi
  if [[ "$low" =~ ^[0-9]+$ ]] && [[ "$low" -gt 1024 ]]; then
    echo "$low"
  else
    echo 32768   # the kernel default
  fi
}

listening_ports() {
  if command -v ss >/dev/null; then
    ss -ltn 2>/dev/null | awk 'NR>1 {print $4}'
  elif command -v netstat >/dev/null; then
    netstat -ltn 2>/dev/null | awk '{print $4}'
  fi
}

# A here-string, not a pipe: `grep -q` stops at the first match, and the SIGPIPE
# that kills the left side reads as failure under pipefail — "free" for a port
# that is anything but.
port_in_use() {
  local port="$1" listeners
  listeners="$(listening_ports || true)"
  if grep -qE "[:.]${port}\$" <<<"$listeners"; then
    return 0
  fi
  if (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
    return 0
  fi
  return 1
}

# Two $RANDOMs: one only reaches 32767, half the range.
pick_port() {
  local low=10000 high span port attempt
  high=$(( $(ephemeral_low) - 1 ))
  if [[ $high -le $low ]]; then
    high=32767
  fi
  span=$(( high - low + 1 ))
  for attempt in $(seq 50); do
    port=$(( low + ((RANDOM << 15 | RANDOM) % span) ))
    if ! port_in_use "$port"; then
      echo "$port"
      return 0
    fi
  done
  return 1
}

# --- the move from the old name -----------------------------------------------
#
# A panel installed under the product's old name is moved before anything else
# looks at this server: its directories, its unit, a node installed beside it
# with the node script, and a PostgreSQL the old script set up here. Every step
# looks before it acts, so a run cut off halfway is finished by the next one,
# and the old name is never left running beside the new one. A snapshot of
# what is moved is taken first; a failure later in the run puts it back.

OLD_INSTALL_DIR="/opt/nexora-panel"   # rebrand-ok
OLD_STATE_DIR="/var/opt/nexora"       # rebrand-ok
OLD_SERVICE="nexora-panel"            # rebrand-ok
OLD_NODE_DIR="/opt/nexora-node"       # rebrand-ok
OLD_NODE_SERVICE="nexora-node"        # rebrand-ok
OLD_PG="nexora"                       # rebrand-ok
NODE_INSTALL_DIR="/opt/nx-node"
NODE_STATE_DIR="/var/opt/nx-node"
NODE_UNIT="/etc/systemd/system/nx-node.service"
# What a node keeps in the state directory the two used to share.
NODE_STATE_ITEMS="certs cache tailscale"

TRANSFERRED=0
TRANSFER_SNAPSHOT=""
TRANSFER_ITEMS=()
NODE_MOVED=0
PG_RENAMED=0
PG_PASS=""

is_node_item() { [[ " ${NODE_STATE_ITEMS} " == *" $1 "* ]]; }

# legacy_node_method is how a node installed under the old name runs here.
legacy_node_method() {
  if command -v docker >/dev/null && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$OLD_NODE_SERVICE"; then
    echo docker
  elif [[ -e "$OLD_NODE_DIR" || -f "/etc/systemd/system/${OLD_NODE_SERVICE}.service" ]]; then
    echo script
  else
    echo none
  fi
}

# pg runs one psql as the server's superuser, its arguments quoted for su.
pg() { su - postgres -c "psql -q -tA -v ON_ERROR_STOP=1 $(printf '%q ' "$@")"; }

pg_has() { [[ "$(pg -c "SELECT 1 FROM $1 WHERE $2 = '$3'")" == 1 ]]; }

pg_hba_rename() {
  local hba
  hba="$(pg -c 'SHOW hba_file' | tr -d '[:space:]')"
  [[ -f "$hba" ]] || return 0
  sed -i -E "s/^host +$1 +$1 +127\.0\.0\.1\/32/host $2 $2 127.0.0.1\/32/" "$hba"
  systemctl reload postgresql >/dev/null 2>&1 || systemctl restart postgresql >/dev/null 2>&1 || true
}

# pg_rename moves the database and its role from one name to the other and sets
# the password again: renaming a role clears an MD5 password.
pg_rename() {
  local from="$1" to="$2"
  if pg_has pg_database datname "$from" && ! pg_has pg_database datname "$to"; then
    pg -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${from}'" >/dev/null
    pg -c "ALTER DATABASE ${from} RENAME TO ${to}" || return 1
  fi
  if pg_has pg_roles rolname "$from" && ! pg_has pg_roles rolname "$to"; then
    pg -c "ALTER ROLE ${from} RENAME TO ${to}" || return 1
  fi
  pg -c "ALTER ROLE ${to} PASSWORD '${PG_PASS}'" || return 1
  pg_hba_rename "$from" "$to"
}

# transfer_postgres renames a database the old script set up on this server,
# which its DSN gives away: the loopback, the default port and both names.
# Anything else is the operator's server and keeps its names (R11).
transfer_postgres() {
  local cfg="$1" dsn
  [[ -f "$cfg" ]] && grep -q '"driver": *"postgres"' "$cfg" || return 0
  dsn="$(sed -n 's/.*"dsn": *"\([^"]*\)".*/\1/p' "$cfg" | head -n1)"
  if [[ ! "$dsn" =~ ^host=127\.0\.0\.1\ port=5432\ user=${OLD_PG}\ password=([0-9a-f]+)\ dbname=${OLD_PG}\ sslmode=disable$ ]]; then
    [[ "$dsn" != *"${OLD_PG}"* ]] ||
      warn "the database is not one this script set up here, so it keeps its name; rename it there if you want to"
    return 0
  fi
  PG_PASS="${BASH_REMATCH[1]}"
  say "renaming the PostgreSQL database and role to ${PG_DB}"
  pg_rename "$OLD_PG" "$PG_DB" || die "could not rename the PostgreSQL database; nothing else was moved"
  PG_RENAMED=1
  sed -i "s/user=${OLD_PG} /user=${PG_USER} /; s/dbname=${OLD_PG} /dbname=${PG_DB} /" "$cfg"
}

# move_into moves src to dst. A dst an earlier run left is merged into, with
# src winning: after a restore, the old place is the one that ran last.
move_into() {
  local src="${1:?}" dst="${2:?}"
  [[ -e "$src" ]] || return 0
  if [[ -d "$src" && -d "$dst" ]]; then
    cp -a "$src"/. "$dst"/ && rm -rf "${src:?}"
  elif [[ -e "$dst" ]]; then
    rm -rf "${dst:?}" && mv "$src" "$dst"
  else
    mkdir -p "$(dirname "$dst")"
    mv "$src" "$dst"
  fi
}

transfer_legacy() {
  local node_method p name parts=()
  TRANSFER_ITEMS=()
  node_method="$(legacy_node_method)"
  if [[ -d "$OLD_STATE_DIR" ]]; then
    for p in "$OLD_STATE_DIR"/* "$OLD_STATE_DIR"/.[!.]*; do
      [[ -e "$p" ]] || continue
      name="${p##*/}"
      is_node_item "$name" || TRANSFER_ITEMS+=("$name")
    done
  fi
  [[ -e "$OLD_INSTALL_DIR" || -f "/etc/systemd/system/${OLD_SERVICE}.service" || ${#TRANSFER_ITEMS[@]} -gt 0 ]] || return 0

  say "moving the panel installed under the old name"
  TRANSFERRED=1
  mkdir -p "$STATE_DIR"

  # The snapshot leaves out what is fetched again (node binaries, rule sets)
  # and the backups, which are copies already.
  [[ -e "$OLD_INSTALL_DIR" ]] && parts+=("${OLD_INSTALL_DIR#/}")
  [[ -f "/etc/systemd/system/${OLD_SERVICE}.service" ]] && parts+=("etc/systemd/system/${OLD_SERVICE}.service")
  for name in "${TRANSFER_ITEMS[@]}"; do
    case "$name" in bin|backups|rulesets) ;; *) parts+=("${OLD_STATE_DIR#/}/${name}") ;; esac
  done
  if [[ "$node_method" == script ]]; then
    [[ -e "$OLD_NODE_DIR" ]] && parts+=("${OLD_NODE_DIR#/}")
    [[ -f "/etc/systemd/system/${OLD_NODE_SERVICE}.service" ]] && parts+=("etc/systemd/system/${OLD_NODE_SERVICE}.service")
    [[ -e "${OLD_STATE_DIR}/certs" ]] && parts+=("${OLD_STATE_DIR#/}/certs")
  fi
  if [[ ${#parts[@]} -gt 0 ]]; then
    TRANSFER_SNAPSHOT="${STATE_DIR}/transfer-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar -C / -czf "$TRANSFER_SNAPSHOT" "${parts[@]}" || die "could not save the old install; nothing was moved"
    chmod 0600 "$TRANSFER_SNAPSHOT"
    say "the old install is saved in ${TRANSFER_SNAPSHOT}"
  fi

  systemctl disable --now "$OLD_SERVICE" >/dev/null 2>&1 || true
  transfer_postgres "${OLD_INSTALL_DIR}/config.json"
  [[ $PG_RENAMED -eq 1 ]] || transfer_postgres "${INSTALL_DIR}/config.json"

  move_into "$OLD_INSTALL_DIR" "$INSTALL_DIR"
  rm -f "${INSTALL_DIR:?}/${OLD_SERVICE:?}" "${INSTALL_DIR:?}/${OLD_SERVICE:?}.previous"
  for name in "${TRANSFER_ITEMS[@]}"; do
    move_into "${OLD_STATE_DIR}/${name}" "${STATE_DIR}/${name}"
  done
  # Staged under the old name; downloaded again below under the new one.
  rm -f "${STATE_DIR:?}/bin/${OLD_NODE_SERVICE:?}-linux-"*
  if [[ -f "${INSTALL_DIR}/config.json" ]]; then
    sed -i "s|${OLD_STATE_DIR}/${OLD_PG}\.db|${STATE_DIR}/nx.db|g; s|${OLD_STATE_DIR}/|${STATE_DIR}/|g; s|${OLD_INSTALL_DIR}|${INSTALL_DIR}|g" \
      "${INSTALL_DIR}/config.json"
  fi
  rm -f "/etc/systemd/system/${OLD_SERVICE:?}.service" "/usr/local/bin/${OLD_SERVICE:?}"
  systemctl daemon-reload

  case "$node_method" in
    script) transfer_node ;;
    docker)
      warn "the node on this server runs in docker under the old name and keeps running;"
      warn "move it from the panel's Nodes page (it is marked \"needs migration\")"
      ;;
  esac
  rmdir "$OLD_STATE_DIR" 2>/dev/null || true
}

# transfer_node moves a node the node script installed beside the panel. It is
# started again under the new name once the panel's downloads have its binary
# (install_moved_node), and keeps the panel's previous certificate until the
# panel updates it — the node stays marked "needs migration" until then.
transfer_node() {
  say "moving the node beside it"
  systemctl disable --now "$OLD_NODE_SERVICE" >/dev/null 2>&1 || true
  local name
  for name in $NODE_STATE_ITEMS; do
    move_into "${OLD_STATE_DIR}/${name}" "${NODE_STATE_DIR}/${name}"
  done
  move_into "$OLD_NODE_DIR" "$NODE_INSTALL_DIR"
  rm -f "${NODE_INSTALL_DIR:?}/${OLD_NODE_SERVICE:?}" "${NODE_INSTALL_DIR:?}/${OLD_NODE_SERVICE:?}.previous" \
    "${NODE_INSTALL_DIR:?}/${OLD_NODE_SERVICE:?}.new"
  if [[ -f "${NODE_INSTALL_DIR}/config.json" ]]; then
    sed -i "s|${OLD_STATE_DIR}/|${NODE_STATE_DIR}/|g; s|${OLD_NODE_DIR}|${NODE_INSTALL_DIR}|g" "${NODE_INSTALL_DIR}/config.json"
  fi
  rm -f "/etc/systemd/system/${OLD_NODE_SERVICE:?}.service"
  systemctl daemon-reload
  NODE_MOVED=1
}

install_moved_node() {
  local bin="${STATE_DIR}/bin/nx-node-${ARCH}"
  [[ -x "$bin" ]] || { rollback; die "no node binary for ${ARCH} to move the node beside the panel with"; }
  install -m 0755 "$bin" "${NODE_INSTALL_DIR}/nx-node"
  cat > "$NODE_UNIT" <<EOF
[Unit]
Description=NX Node
After=network.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${NODE_STATE_DIR}
Environment=NX_STATE_DIR=${NODE_STATE_DIR}
ExecStart=${NODE_INSTALL_DIR}/nx-node run -config ${NODE_INSTALL_DIR}/config.json
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now nx-node >/dev/null
  local i
  for i in $(seq 30); do
    systemctl is-active --quiet nx-node && break
    sleep 0.5
  done
  systemctl is-active --quiet nx-node || {
    journalctl -u nx-node -n 30 --no-pager || true
    rollback
    die "the node did not start under its new name (log above)"
  }
  say "the node beside the panel runs as nx-node"
}

# restore_transfer puts the old install back from its snapshot, after a failure
# later in a run that moved it.
restore_transfer() {
  [[ ${RESTORED:-0} -eq 0 ]] || return 0
  RESTORED=1
  warn "putting the old install back"
  systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
  rm -f "$UNIT" "/usr/local/bin/${SERVICE:?}"
  if [[ $NODE_MOVED -eq 1 ]]; then
    systemctl disable --now nx-node >/dev/null 2>&1 || true
    rm -f "$NODE_UNIT"
  fi
  [[ $PG_RENAMED -eq 0 ]] || pg_rename "$PG_DB" "$OLD_PG" || warn "could not rename the database back to ${OLD_PG}"
  # What was moved goes back first; the snapshot then puts back the files it
  # holds as they were before the run (the database before its migration).
  local name
  for name in "${TRANSFER_ITEMS[@]}"; do
    move_into "${STATE_DIR}/${name}" "${OLD_STATE_DIR}/${name}"
  done
  if [[ $NODE_MOVED -eq 1 ]]; then
    for name in $NODE_STATE_ITEMS; do
      move_into "${NODE_STATE_DIR}/${name}" "${OLD_STATE_DIR}/${name}"
    done
  fi
  # A database this run already migrated is stale now: the restored one is the
  # install's, and the next run moves it again.
  rm -f "${STATE_DIR:?}/nx.db" "${STATE_DIR:?}/nx.db-wal" "${STATE_DIR:?}/nx.db-shm"
  [[ -z "$TRANSFER_SNAPSHOT" ]] || tar -C / -xzf "$TRANSFER_SNAPSHOT" || warn "could not unpack ${TRANSFER_SNAPSHOT}"
  systemctl daemon-reload
  systemctl enable --now "$OLD_SERVICE" >/dev/null 2>&1 || true
  [[ $NODE_MOVED -eq 0 ]] || systemctl enable --now "$OLD_NODE_SERVICE" >/dev/null 2>&1 || true
  warn "the old install runs again; re-running this script tries the move again"
}

# --- install ------------------------------------------------------------------

# on_exit puts a moved install back when the run stops early for any reason —
# a die, or a command that failed under set -e — and not after it finished.
TRANSFER_DONE=0
on_exit() {
  local rc=$?
  [[ $rc -eq 0 || $TRANSFERRED -eq 0 || $TRANSFER_DONE -eq 1 ]] || restore_transfer
  return $rc
}
trap on_exit EXIT

transfer_legacy

UPDATING=0
[[ -x "${INSTALL_DIR}/nx-panel" || -f "${INSTALL_DIR}/config.json" || $TRANSFERRED -eq 1 ]] && UPDATING=1

if [[ $TRANSFERRED -eq 1 ]]; then
  say "installing NX Panel over the moved install"
elif [[ $UPDATING -eq 1 ]]; then
  say "updating an existing install ($(panel_version || echo unknown))"
  systemctl stop "$SERVICE" 2>/dev/null || true
else
  say "installing NX Panel (${ARCH})"
fi

mkdir -p "$INSTALL_DIR" "${STATE_DIR}/bin" "${STATE_DIR}/sub-themes" "${STATE_DIR}/backups"
# Backups hold every credential the panel has.
chmod 0700 "${STATE_DIR}/backups"

TMP="$(mktemp -d)"
trap 'rc=$?; rm -rf "$TMP"; (exit $rc); on_exit' EXIT

say "downloading the panel"
curl -fsSL "$(asset_url "$PANEL_REPO" "$PANEL_VERSION" "nx-panel-${ARCH}.tar.gz")" -o "${TMP}/panel.tar.gz" ||
  die "could not download the panel for ${ARCH}"
tar -C "$TMP" -xzf "${TMP}/panel.tar.gz"

if [[ -x "${INSTALL_DIR}/nx-panel" ]]; then
  cp -f "${INSTALL_DIR}/nx-panel" "${INSTALL_DIR}/nx-panel.previous"
fi
install -m 0755 "${TMP}/nx-panel/nx-panel" "${INSTALL_DIR}/nx-panel"

# The panel serves these to node installers from bin/. The tag comes from the
# redirect "latest" answers with: a binary carries no release tag.
resolve_node_version() {
  [[ -n "$NODE_VERSION" ]] && { echo "$NODE_VERSION"; return; }
  [[ -n "${NX_DOWNLOAD_BASE:-}" ]] && return 0   # a mirror has no tag to ask for
  local url
  url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
    "https://github.com/${NODE_REPO}/releases/latest" 2>/dev/null || true)"
  case "$url" in
    */releases/tag/*) echo "${url##*/}" ;;
  esac
}

say "downloading node binaries"
NODE_TAG="$(resolve_node_version)"
for node_arch in amd64 arm64; do
  if curl -fsSL "$(asset_url "$NODE_REPO" "$NODE_VERSION" "nx-node-linux-${node_arch}.tar.gz")" -o "${TMP}/node.tar.gz" 2>/dev/null; then
    tar -C "$TMP" -xzf "${TMP}/node.tar.gz"
    install -m 0755 "${TMP}/nx-node/nx-node" "${STATE_DIR}/bin/nx-node-linux-${node_arch}"
    if [[ -n "$NODE_TAG" ]]; then
      printf '%s\n' "$NODE_TAG" > "${STATE_DIR}/bin/nx-node-linux-${node_arch}.version"
    else
      rm -f "${STATE_DIR}/bin/nx-node-linux-${node_arch}.version"
    fi
  else
    warn "no node binary published for linux-${node_arch}; nodes on that architecture must be installed manually"
  fi
done

# Never touched on an update: the operator's DSN lives here.
if [[ ! -f "${INSTALL_DIR}/config.json" ]]; then
  if [[ $USE_POSTGRES -eq 1 ]]; then
    DSN="$(setup_postgres)"
    cat > "${INSTALL_DIR}/config.json" <<EOF
{
  "db": {
    "driver": "postgres",
    "dsn": "${DSN}",
    "verbose": false
  }
}
EOF
  else
    cat > "${INSTALL_DIR}/config.json" <<EOF
{
  "db": {
    "driver": "sqlite",
    "dsn": "${STATE_DIR}/nx.db",
    "verbose": false
  }
}
EOF
  fi
  chmod 0600 "${INSTALL_DIR}/config.json"
elif [[ $USE_POSTGRES -eq 1 ]]; then
  warn "config.json already exists; leaving the database configuration alone"
fi

# One file, so a copy is a complete rollback point; PostgreSQL is not.
if [[ $UPDATING -eq 1 ]] && [[ -f "${STATE_DIR}/nx.db" ]]; then
  cp -f "${STATE_DIR}/nx.db" "${STATE_DIR}/nx.db.bak"
  say "database backed up to ${STATE_DIR}/nx.db.bak"
fi

rollback() {
  [[ $UPDATING -eq 1 ]] || return 0
  if [[ $TRANSFERRED -eq 1 ]]; then
    restore_transfer
    return 0
  fi
  [[ -f "${INSTALL_DIR}/nx-panel.previous" ]] || return 0
  warn "restoring the previous version"
  mv -f "${INSTALL_DIR}/nx-panel.previous" "${INSTALL_DIR}/nx-panel"
  systemctl start "$SERVICE" 2>/dev/null || true
}

say "migrating the database"
if ! ( cd "$STATE_DIR" && "${INSTALL_DIR}/nx-panel" migrate -config "${INSTALL_DIR}/config.json" ); then
  rollback
  die "the database migration failed; nothing was changed"
fi

# Once, on a panel that has never been configured — `config get` failing is what
# says so. Unset means the binary's own [::]:2095, so a failure still comes up.
if [[ $UPDATING -eq 0 ]] && ! nx_panel config get web_listen_port >/dev/null 2>&1; then
  if LISTEN_PORT="$(pick_port)"; then
    if nx_panel config set web_listen_port "$LISTEN_PORT" >/dev/null 2>&1; then
      say "the panel will listen on port ${LISTEN_PORT}"
    else
      warn "could not save the chosen port; the panel will use its default"
    fi
  else
    warn "found no free port to give the panel; it will use its default"
  fi
fi

cat > "$UNIT" <<EOF
[Unit]
Description=NX Panel
After=network.target postgresql.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${STATE_DIR}
Environment=NX_STATE_DIR=${STATE_DIR}
ExecStart=${INSTALL_DIR}/nx-panel run -config ${INSTALL_DIR}/config.json
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

ln -sf "${INSTALL_DIR}/nx-panel" /usr/local/bin/nx-panel 2>/dev/null || true

systemctl daemon-reload
systemctl enable --now "$SERVICE" >/dev/null

for _ in $(seq 30); do
  systemctl is-active --quiet "$SERVICE" && break
  sleep 0.5
done
systemctl is-active --quiet "$SERVICE" || {
  journalctl -u "$SERVICE" -n 30 --no-pager || true
  rollback
  die "the panel did not start (log above)"
}
[[ $NODE_MOVED -eq 0 ]] || install_moved_node
TRANSFER_DONE=1

echo
if [[ $UPDATING -eq 1 ]]; then
  if [[ $TRANSFERRED -eq 1 ]]; then
    say "moved to NX $(panel_version)"
    echo "  Your settings, database and admins came along. The old install is saved"
    echo "  in ${TRANSFER_SNAPSHOT:-(nothing to save)}; delete it once the panel works."
    echo "  Nodes and addons are marked \"needs migration\" on their pages: update"
    echo "  each one there, which moves it to NX as well."
    exit 0
  fi
  say "NX updated to $(panel_version)"
  echo "  Nothing else to do — your settings, database and admins are unchanged."
  exit 0
fi

# --- first run ----------------------------------------------------------------

TOKEN="$(nx_panel setup-token 2>/dev/null || true)"
PORT="$(nx_panel config get web_listen_port 2>/dev/null || echo 2095)"
[[ -n "$PORT" ]] || PORT=2095

# Only the operator knows which address reaches this server, so every candidate
# is printed. Several lookup services: any one can be blocked or down.
public_ip() {
  local url ip
  for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip="$(curl -fsS --max-time 5 "$url" 2>/dev/null || true)"
    ip="${ip//[[:space:]]/}"
    # A blocked request often answers with an HTML error page, not a failure.
    if [[ "$ip" =~ ^[0-9a-fA-F:.]+$ ]] && [[ -n "$ip" ]]; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

local_ips() {
  if command -v ip >/dev/null; then
    ip -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' || true
  else
    hostname -I 2>/dev/null | tr ' ' '\n' || true
  fi
}

setup_link() {
  local addr="$1"
  if [[ "$addr" == *:* ]]; then
    addr="[${addr}]"
  fi
  echo "http://${addr}:${PORT}/setup?t=${TOKEN}"
}

say "NX $(panel_version) is installed"
echo
if [[ -n "$TOKEN" ]]; then
  echo "  Finish the setup by opening one of these links — whichever address"
  echo "  reaches this server from where you are:"
  echo
  PUBLIC=""
  if PUBLIC="$(public_ip)"; then
    printf '    %-52s %s\n' "$(setup_link "$PUBLIC")" "(as the internet sees this host)"
  fi
  while read -r addr; do
    if [[ -z "$addr" || "$addr" == "$PUBLIC" ]]; then
      continue
    fi
    printf '    %s\n' "$(setup_link "$addr")"
  done < <(local_ips)
  echo
  if [[ -n "${LISTEN_PORT:-}" && "${LISTEN_PORT:-}" == "$PORT" ]]; then
    echo "  Port ${PORT} was picked at random and is free on this host — open it in"
    echo "  the firewall if one is running. The wizard can move it before you finish."
    echo
  fi
  echo "  Until setup is finished the panel answers nothing else, and nothing at"
  echo "  all without that token — so keep the link private. To print it again:"
  echo
  echo "    nx-panel setup-token"
else
  echo "  This panel is already set up. Sign in on port ${PORT}."
  echo "  Locked out? Stop the service, then: nx-panel admin reset-password"
fi
echo
echo "  Service:  systemctl status ${SERVICE}"
echo "  Logs:     journalctl -u ${SERVICE} -f"
echo "  Backups:  ${STATE_DIR}/backups  (turn the schedule on under Settings → Backup)"
echo
