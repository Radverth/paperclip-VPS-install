#!/usr/bin/env bash
# =============================================================================
# Paperclip installer — Contabo VPS
#
# Installs Paperclip (AI-company orchestration) as a systemd service that runs
# as the `bridge` user, so agents reuse the Claude Code / Codex CLI
# subscription logins that user already has. Served by the host Caddy with
# HTTPS and a login screen (authenticated + public mode).
#
# Public mode needs a real Postgres, so the script runs a dedicated
# `paperclip_postgres` Docker container bound to 127.0.0.1 only (n8n's
# database is not touched).
#
# Usage (as your sudo user, NOT as bridge):
#   sudo bash install-paperclip.sh
#
# Optional overrides:
#   sudo DOMAIN=paperclip.example.com RUN_USER=bridge bash install-paperclip.sh
#   sudo DATABASE_URL=postgres://... bash install-paperclip.sh  # use your own Postgres
#   sudo FORCE_REINSTALL=1 bash install-paperclip.sh   # back up + rebuild instance and DB
#
# Safe to re-run: existing instance, database, service and Caddy block are reused.
# =============================================================================
set -euo pipefail

DOMAIN="${DOMAIN:-paperclip.n8ntom.duckdns.org}"
RUN_USER="${RUN_USER:-bridge}"
PORT="${PORT:-3100}"
CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
FORCE_REINSTALL="${FORCE_REINSTALL:-0}"
DB_PORT="${DB_PORT:-5433}"
DB_CONTAINER="paperclip_postgres"
DB_VOLUME="paperclip_pgdata"
DB_IMAGE="postgres:17"
MIN_NODE="24.11.0"
SERVICE="paperclip"
USER_DATABASE_URL="${DATABASE_URL:-}"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Run with sudo: sudo bash $0"
id "$RUN_USER" &>/dev/null || die "User '$RUN_USER' does not exist"

RUN_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"
INSTANCE_DIR="$RUN_HOME/.paperclip/instances/default"
ENV_FILE="$RUN_HOME/paperclip.env"
UNIT_FILE="/etc/systemd/system/${SERVICE}.service"
PUBLIC_URL="https://${DOMAIN}"
ONBOARD_LOG="/tmp/paperclip-onboard.$$.log"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$RUN_HOME/.paperclip.bak.$STAMP"

log "Preflight checks"
for bin in curl ss caddy systemctl docker; do
  command -v "$bin" &>/dev/null || die "'$bin' not found"
done
command -v dig &>/dev/null || apt-get install -y -qq dnsutils >/dev/null
ok "Required tools present"

RESOLVED="$(dig +short "$DOMAIN" | tail -n1 || true)"
MY_IP="$(curl -fsS --max-time 5 https://api.ipify.org || true)"
if [[ -z "$RESOLVED" ]]; then
  die "$DOMAIN does not resolve. Fix DNS first."
elif [[ -n "$MY_IP" && "$RESOLVED" != "$MY_IP" ]]; then
  warn "$DOMAIN resolves to $RESOLVED but this server is $MY_IP"
else
  ok "$DOMAIN -> $RESOLVED"
fi

# ---------------------------------------------------------------------------
# Node.js 24+ (system Node; the service always uses this one)
# ---------------------------------------------------------------------------
log "Checking Node.js (need >= $MIN_NODE)"
CUR_NODE="$(/usr/bin/node --version 2>/dev/null | sed 's/^v//' || true)"
if [[ -z "$CUR_NODE" ]] || ! printf '%s\n%s\n' "$MIN_NODE" "$CUR_NODE" | sort -V -C; then
  warn "System Node ${CUR_NODE:-not installed} — installing Node 24 from NodeSource"
  curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
  apt-get install -y nodejs
  CUR_NODE="$(/usr/bin/node --version | sed 's/^v//')"
fi
ok "Node v$CUR_NODE"
npm install -g corepack >/dev/null 2>&1 && corepack enable >/dev/null 2>&1 || warn "corepack setup skipped"
NPX_BIN="/usr/bin/npx"
[[ -x "$NPX_BIN" ]] || die "$NPX_BIN not found after Node install"

# ---------------------------------------------------------------------------
# bridge's full PATH
# Tools added near the end of ~/.bashrc (nvm, npm prefix, ~/.local/bin) are
# skipped by non-interactive shells, so read PATH from an interactive shell,
# then put system Node first so the service never runs on an older nvm Node.
# ---------------------------------------------------------------------------
IPATH="$(sudo -u "$RUN_USER" -H bash -ic 'printf "__PATH__%s\n" "$PATH"' 2>/dev/null </dev/null \
  | sed -n 's/^__PATH__//p' | tail -n1 || true)"
[[ -n "$IPATH" ]] || IPATH="$(sudo -u "$RUN_USER" -H bash -lc 'echo "$PATH"')"
EXTRA=""
for d in "$RUN_HOME/.local/bin" "$RUN_HOME/.npm-global/bin" "$RUN_HOME/bin"; do
  [[ -d "$d" && ":$IPATH:" != *":$d:"* ]] && EXTRA="$EXTRA:$d"
done
USER_PATH="/usr/local/bin:/usr/bin:/bin${EXTRA}:${IPATH}"

# Run a command as RUN_USER with that PATH and API keys stripped, so CLIs use
# subscription auth.
as_user() {
  sudo -u "$RUN_USER" -H env PATH="$USER_PATH" bash -c "unset ANTHROPIC_API_KEY OPENAI_API_KEY; cd ~; $1"
}

stop_paperclip_procs() {
  pkill -TERM -u "$RUN_USER" -f 'paperclipai' 2>/dev/null || true
  sleep 3
  pkill -TERM -u "$RUN_USER" -f "$RUN_HOME/.paperclip" 2>/dev/null || true
  sleep 2
  pkill -KILL -u "$RUN_USER" -f 'paperclipai' 2>/dev/null || true
  pkill -KILL -u "$RUN_USER" -f "$RUN_HOME/.paperclip" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Agent CLIs + auth sanity
# ---------------------------------------------------------------------------
log "Checking agent CLIs for $RUN_USER"
if CLAUDE_PATH="$(as_user 'command -v claude')"; then
  ok "claude: $CLAUDE_PATH ($(as_user 'claude --version' 2>/dev/null | head -n1))"
else
  warn "claude not found for $RUN_USER — claude_local agents won't run"
fi
if CODEX_PATH="$(as_user 'command -v codex')"; then
  ok "codex: $CODEX_PATH ($(as_user 'codex --version' 2>/dev/null | head -n1))"
else
  warn "codex not found for $RUN_USER — codex_local agents won't run"
  OTHER="$(ls -1 /root/.npm-global/bin/codex /root/.local/bin/codex /usr/local/bin/codex 2>/dev/null | head -n1 || true)"
  [[ -n "$OTHER" ]] && warn "Found $OTHER — that install isn't visible to $RUN_USER; install codex for $RUN_USER and run 'codex login' as them"
fi

for rc in .bashrc .profile .bash_profile; do
  if [[ -f "$RUN_HOME/$rc" ]] && grep -Eq '^[^#]*(ANTHROPIC_API_KEY|OPENAI_API_KEY)' "$RUN_HOME/$rc"; then
    warn "$rc sets an API key — the service ignores it, but interactive runs would bill the API"
  fi
done

# ---------------------------------------------------------------------------
# Stop anything already running
# ---------------------------------------------------------------------------
if systemctl list-unit-files "${SERVICE}.service" &>/dev/null; then
  systemctl stop "$SERVICE" 2>/dev/null || true
  systemctl reset-failed "$SERVICE" 2>/dev/null || true
fi
stop_paperclip_procs
if ss -ltn "sport = :$PORT" | grep -q LISTEN; then
  die "Port $PORT is in use by something else: $(ss -ltnp "sport = :$PORT" | tail -n1)"
fi

# ---------------------------------------------------------------------------
# Force reinstall: back up instance (and DB below)
# ---------------------------------------------------------------------------
if [[ "$FORCE_REINSTALL" == "1" && -d "$RUN_HOME/.paperclip" ]]; then
  log "FORCE_REINSTALL=1 — moving existing instance to $BACKUP_DIR"
  mv "$RUN_HOME/.paperclip" "$BACKUP_DIR"
fi

# ---------------------------------------------------------------------------
# Postgres
# ---------------------------------------------------------------------------
EXISTING_URL=""
[[ -f "$ENV_FILE" ]] && EXISTING_URL="$(grep -E '^DATABASE_URL=' "$ENV_FILE" | cut -d= -f2- || true)"
container_exists() { docker ps -a --format '{{.Names}}' | grep -qx "$DB_CONTAINER"; }

if [[ -n "$USER_DATABASE_URL" ]]; then
  log "Using DATABASE_URL you supplied"
  DATABASE_URL="$USER_DATABASE_URL"
else
  log "Setting up Postgres container ($DB_CONTAINER on 127.0.0.1:$DB_PORT)"

  if [[ "$FORCE_REINSTALL" == "1" ]] && container_exists; then
    mkdir -p "$BACKUP_DIR"
    docker start "$DB_CONTAINER" >/dev/null 2>&1 || true
    sleep 3
    if docker exec "$DB_CONTAINER" pg_dump -U paperclip paperclip >"$BACKUP_DIR/paperclip-db.sql" 2>/dev/null; then
      ok "Database dumped to $BACKUP_DIR/paperclip-db.sql"
    else
      warn "Could not dump old database (it may have been empty)"
    fi
    docker rm -f "$DB_CONTAINER" >/dev/null
    docker volume rm "$DB_VOLUME" >/dev/null 2>&1 || true
    EXISTING_URL=""
  fi

  if container_exists; then
    [[ -n "$EXISTING_URL" ]] || die "$DB_CONTAINER exists but $ENV_FILE has no DATABASE_URL. Re-run with FORCE_REINSTALL=1 to rebuild it."
    DATABASE_URL="$EXISTING_URL"
    docker start "$DB_CONTAINER" >/dev/null
    ok "Reusing existing $DB_CONTAINER"
  else
    if ss -ltn "sport = :$DB_PORT" | grep -q LISTEN; then
      die "Port $DB_PORT is in use. Re-run with DB_PORT=<free port>."
    fi
    DB_PASS="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    docker run -d --name "$DB_CONTAINER" --restart unless-stopped \
      -e POSTGRES_USER=paperclip -e POSTGRES_PASSWORD="$DB_PASS" -e POSTGRES_DB=paperclip \
      -p "127.0.0.1:${DB_PORT}:5432" \
      -v "${DB_VOLUME}:/var/lib/postgresql/data" \
      "$DB_IMAGE" >/dev/null
    DATABASE_URL="postgres://paperclip:${DB_PASS}@127.0.0.1:${DB_PORT}/paperclip"
    ok "Created $DB_CONTAINER"
  fi

  for _ in $(seq 1 60); do
    docker exec "$DB_CONTAINER" pg_isready -U paperclip -d paperclip >/dev/null 2>&1 && break
    sleep 1
  done
  docker exec "$DB_CONTAINER" pg_isready -U paperclip -d paperclip >/dev/null 2>&1 \
    || die "Postgres did not become ready. Check: docker logs $DB_CONTAINER"
  ok "Postgres ready"
fi

PC_EXPORTS="export PAPERCLIP_DEPLOYMENT_MODE=authenticated \
PAPERCLIP_DEPLOYMENT_EXPOSURE=public \
PAPERCLIP_AUTH_BASE_URL_MODE=explicit \
PAPERCLIP_PUBLIC_URL='${PUBLIC_URL}' \
PAPERCLIP_AUTH_PUBLIC_BASE_URL='${PUBLIC_URL}' \
PAPERCLIP_ALLOWED_HOSTNAMES='${DOMAIN}' \
DATABASE_URL='${DATABASE_URL}'"

# ---------------------------------------------------------------------------
# Onboard (creates config, initialises DB, secrets key)
# ---------------------------------------------------------------------------
if [[ -f "$INSTANCE_DIR/config.json" ]]; then
  log "Existing instance found — reusing it (FORCE_REINSTALL=1 to rebuild)"
else
  log "Onboarding Paperclip as $RUN_USER (first run downloads packages)"
  as_user "$PC_EXPORTS; exec $NPX_BIN --yes paperclipai onboard --yes" \
    >"$ONBOARD_LOG" 2>&1 </dev/null &
  OB_PID=$!

  # Onboarding may start the server and keep running; wait until the config
  # exists and the port is up (or the process exits), then stop it so systemd
  # can take over.
  for _ in $(seq 1 600); do
    kill -0 "$OB_PID" 2>/dev/null || break
    if [[ -f "$INSTANCE_DIR/config.json" ]] && ss -ltn "sport = :$PORT" | grep -q LISTEN; then
      sleep 3; break
    fi
    sleep 1
  done
  stop_paperclip_procs
  wait "$OB_PID" 2>/dev/null || true

  if [[ ! -f "$INSTANCE_DIR/config.json" ]]; then
    tail -n 40 "$ONBOARD_LOG" || true
    die "Onboarding did not create $INSTANCE_DIR/config.json (full log: $ONBOARD_LOG)"
  fi
  ok "Instance created at $INSTANCE_DIR"
fi

# Public mode needs auth.baseUrlMode=explicit + auth.publicBaseUrl in the
# config itself; onboard --yes doesn't always write them, so set them here.
log "Setting public auth URL in config.json"
CFG_FILE="$INSTANCE_DIR/config.json"
cp "$CFG_FILE" "$CFG_FILE.bak.$STAMP"
CFG_FILE="$CFG_FILE" PUBLIC_URL="$PUBLIC_URL" DOMAIN="$DOMAIN" /usr/bin/node -e '
  const fs = require("fs");
  const f = process.env.CFG_FILE;
  const c = JSON.parse(fs.readFileSync(f, "utf8"));
  c.auth = Object.assign({}, c.auth, {
    baseUrlMode: "explicit",
    publicBaseUrl: process.env.PUBLIC_URL,
  });
  c.server = c.server || {};
  const hosts = new Set(c.server.allowedHostnames || []);
  hosts.add(process.env.DOMAIN);
  c.server.allowedHostnames = [...hosts];
  fs.writeFileSync(f, JSON.stringify(c, null, 2) + "\n");
' || die "Could not update $CFG_FILE"
chown "$RUN_USER:$RUN_USER" "$CFG_FILE"
ok "auth.baseUrlMode=explicit, auth.publicBaseUrl=$PUBLIC_URL"

# ---------------------------------------------------------------------------
# Env file + systemd unit
# ---------------------------------------------------------------------------
log "Writing $ENV_FILE"
umask 077
cat >"$ENV_FILE" <<EOF
PAPERCLIP_DEPLOYMENT_MODE=authenticated
PAPERCLIP_DEPLOYMENT_EXPOSURE=public
PAPERCLIP_AUTH_BASE_URL_MODE=explicit
PAPERCLIP_PUBLIC_URL=${PUBLIC_URL}
PAPERCLIP_AUTH_PUBLIC_BASE_URL=${PUBLIC_URL}
PAPERCLIP_ALLOWED_HOSTNAMES=${DOMAIN}
DATABASE_URL=${DATABASE_URL}
PATH=${USER_PATH}
EOF
umask 022
chown "$RUN_USER:$RUN_USER" "$ENV_FILE"
chmod 600 "$ENV_FILE"

log "Writing $UNIT_FILE"
cat >"$UNIT_FILE" <<EOF
[Unit]
Description=Paperclip control plane
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_USER}
WorkingDirectory=${RUN_HOME}
Environment=HOME=${RUN_HOME}
EnvironmentFile=${ENV_FILE}
ExecStart=${NPX_BIN} --yes paperclipai run
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl reset-failed "$SERVICE" 2>/dev/null || true
systemctl enable --now "$SERVICE"

log "Waiting for Paperclip on 127.0.0.1:$PORT"
UP=0
for _ in $(seq 1 180); do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT" -H "Host: $DOMAIN" || true)"
  if [[ "$CODE" != "000" ]]; then UP=1; break; fi
  sleep 1
done
if [[ $UP -ne 1 ]]; then
  journalctl -u "$SERVICE" -n 40 --no-pager || true
  die "Paperclip did not come up. Check: journalctl -u $SERVICE -f"
fi
ok "Paperclip is running (HTTP $CODE)"

# ---------------------------------------------------------------------------
# Caddy
# ---------------------------------------------------------------------------
log "Configuring Caddy"
if grep -Eq "^[[:space:]]*${DOMAIN//./\\.}[[:space:]]*\{" "$CADDYFILE"; then
  ok "Caddy block for $DOMAIN already present"
else
  CADDY_BAK="${CADDYFILE}.bak.$STAMP"
  cp "$CADDYFILE" "$CADDY_BAK"
  cat >>"$CADDYFILE" <<EOF

${DOMAIN} {
    reverse_proxy 127.0.0.1:${PORT}
}
EOF
  if ! caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
    cp "$CADDY_BAK" "$CADDYFILE"
    die "Caddyfile failed validation — restored $CADDY_BAK"
  fi
  ok "Added $DOMAIN to $CADDYFILE"
fi
systemctl reload caddy

log "Waiting for HTTPS at $PUBLIC_URL (certificate issuance can take a minute)"
HTTPS_OK=0
for _ in $(seq 1 90); do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' "$PUBLIC_URL" || true)"
  if [[ "$CODE" =~ ^[23] ]]; then HTTPS_OK=1; break; fi
  sleep 2
done
if [[ $HTTPS_OK -eq 1 ]]; then ok "$PUBLIC_URL is live"
else warn "HTTPS not answering yet — check: journalctl -u caddy -f"; fi

# ---------------------------------------------------------------------------
# Firewall sanity
# ---------------------------------------------------------------------------
if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -Eq "^(${PORT}|${DB_PORT})\b"; then
  warn "UFW has a rule for port $PORT or $DB_PORT — remove it so only Caddy (80/443) faces the internet"
fi

# ---------------------------------------------------------------------------
# First login invite
# ---------------------------------------------------------------------------
log "Generating first-user (CEO) invite"
INVITE_OUT="$(as_user "set -a; . '$ENV_FILE'; set +a; $NPX_BIN --yes paperclipai auth bootstrap-ceo --base-url '$PUBLIC_URL'" 2>&1 || true)"
INVITE_URL="$(grep -Eo 'https?://[^ ]+/invite/[^ ]+' <<<"$INVITE_OUT" | head -n1 || true)"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
cat <<EOF

=============================================================
 Paperclip installed
=============================================================
 URL:      ${PUBLIC_URL}
 Runs as:  ${RUN_USER}  (service: ${SERVICE})
 Instance: ${INSTANCE_DIR}
 Database: ${DB_CONTAINER} on 127.0.0.1:${DB_PORT}
EOF
if [[ -n "$INVITE_URL" ]]; then
  echo " Invite:   ${INVITE_URL}"
  echo "           Open this on your phone to create your login."
else
  echo " Invite:   not generated (an owner may already exist). To create one:"
  echo "           sudo -iu ${RUN_USER} bash -c 'set -a; . ~/paperclip.env; set +a; npx paperclipai auth bootstrap-ceo --force'"
fi
cat <<EOF

 BACK UP THESE OFF THE VPS:
   ${INSTANCE_DIR}/secrets/master.key   (encrypts every stored secret)
   ${ENV_FILE}                         (holds the DB password)

 Useful commands:
   journalctl -u ${SERVICE} -f              # logs
   sudo systemctl restart ${SERVICE}        # restart
   docker logs ${DB_CONTAINER}         # database logs
=============================================================
EOF
