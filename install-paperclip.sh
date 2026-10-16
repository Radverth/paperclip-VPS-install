#!/usr/bin/env bash
# =============================================================================
# Paperclip installer — Contabo VPS
#
# Installs Paperclip (AI-company orchestration) as a systemd service that runs
# as the `bridge` user, so agents reuse the Claude Code / Codex CLI
# subscription logins that user already has. Served by the host Caddy with
# HTTPS and a login screen (authenticated + public mode).
#
# Usage (as your sudo user, NOT as bridge):
#   sudo bash install-paperclip.sh
#
# Optional overrides:
#   sudo DOMAIN=paperclip.example.com RUN_USER=bridge bash install-paperclip.sh
#   sudo FORCE_REINSTALL=1 bash install-paperclip.sh   # back up + rebuild instance
#
# Safe to re-run: existing instance, service and Caddy block are reused.
# =============================================================================
set -euo pipefail

DOMAIN="${DOMAIN:-paperclip.n8ntom.duckdns.org}"
RUN_USER="${RUN_USER:-bridge}"
PORT="${PORT:-3100}"
CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
FORCE_REINSTALL="${FORCE_REINSTALL:-0}"
MIN_NODE="24.11.0"
SERVICE="paperclip"

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

PC_EXPORTS="export PAPERCLIP_DEPLOYMENT_MODE=authenticated \
PAPERCLIP_DEPLOYMENT_EXPOSURE=public \
PAPERCLIP_AUTH_PUBLIC_BASE_URL=${PUBLIC_URL} \
PAPERCLIP_ALLOWED_HOSTNAMES=${DOMAIN}"

# Run a command as RUN_USER with a login shell (gets their PATH: claude, codex,
# npm globals) but with API keys stripped so subscription auth is used.
as_user() {
  sudo -u "$RUN_USER" -H bash -lc "unset ANTHROPIC_API_KEY OPENAI_API_KEY; cd ~; $1"
}

stop_paperclip_procs() {
  pkill -TERM -u "$RUN_USER" -f 'paperclipai' 2>/dev/null || true
  sleep 3
  pkill -TERM -u "$RUN_USER" -f "$RUN_HOME/.paperclip" 2>/dev/null || true
  sleep 2
  pkill -KILL -u "$RUN_USER" -f 'paperclipai' 2>/dev/null || true
  pkill -KILL -u "$RUN_USER" -f "$RUN_HOME/.paperclip" 2>/dev/null || true
}

log "Preflight checks"
for bin in curl ss caddy systemctl; do
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
# Node.js 24+
# ---------------------------------------------------------------------------
log "Checking Node.js (need >= $MIN_NODE)"
CUR_NODE="$(node --version 2>/dev/null | sed 's/^v//' || true)"
if [[ -z "$CUR_NODE" ]] || ! printf '%s\n%s\n' "$MIN_NODE" "$CUR_NODE" | sort -V -C; then
  warn "Node ${CUR_NODE:-not installed} — installing Node 24 from NodeSource"
  curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
  apt-get install -y nodejs
  CUR_NODE="$(node --version | sed 's/^v//')"
fi
ok "Node v$CUR_NODE"
npm install -g corepack >/dev/null 2>&1 && corepack enable >/dev/null 2>&1 || warn "corepack setup skipped"

# ---------------------------------------------------------------------------
# Agent CLIs + auth sanity
# ---------------------------------------------------------------------------
log "Checking agent CLIs for $RUN_USER"
as_user 'command -v claude' >/dev/null && ok "claude: $(as_user 'claude --version' 2>/dev/null | head -n1)" \
  || warn "claude CLI not on $RUN_USER's PATH — claude_local agents won't run"
as_user 'command -v codex' >/dev/null && ok "codex: $(as_user 'codex --version' 2>/dev/null | head -n1)" \
  || warn "codex CLI not on $RUN_USER's PATH — codex_local agents won't run"

for rc in .bashrc .profile .bash_profile; do
  if [[ -f "$RUN_HOME/$rc" ]] && grep -Eq '^[^#]*(ANTHROPIC_API_KEY|OPENAI_API_KEY)' "$RUN_HOME/$rc"; then
    warn "$rc sets an API key — the service ignores it, but interactive runs would bill the API"
  fi
done

USER_PATH="$(as_user 'echo $PATH')"
NPX_BIN="$(as_user 'command -v npx')"
[[ -n "$NPX_BIN" ]] || die "npx not found for $RUN_USER"

# ---------------------------------------------------------------------------
# Port + existing service
# ---------------------------------------------------------------------------
if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
  log "Stopping existing $SERVICE service"
  systemctl stop "$SERVICE"
fi
stop_paperclip_procs
if ss -ltn "sport = :$PORT" | grep -q LISTEN; then
  die "Port $PORT is in use by something else: $(ss -ltnp "sport = :$PORT" | tail -n1)"
fi

# ---------------------------------------------------------------------------
# Onboard (creates config, embedded Postgres, secrets key)
# ---------------------------------------------------------------------------
if [[ -f "$INSTANCE_DIR/config.json" && "$FORCE_REINSTALL" == "1" ]]; then
  BACKUP="$RUN_HOME/.paperclip.bak.$(date +%Y%m%d-%H%M%S)"
  log "FORCE_REINSTALL=1 — moving existing instance to $BACKUP"
  mv "$RUN_HOME/.paperclip" "$BACKUP"
fi

if [[ -f "$INSTANCE_DIR/config.json" ]]; then
  log "Existing instance found — reusing it (FORCE_REINSTALL=1 to rebuild)"
else
  log "Onboarding Paperclip as $RUN_USER (first run downloads packages)"
  sudo -u "$RUN_USER" -H bash -lc "unset ANTHROPIC_API_KEY OPENAI_API_KEY; cd ~; $PC_EXPORTS; exec $NPX_BIN --yes paperclipai onboard --yes" \
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

# ---------------------------------------------------------------------------
# Env file + systemd unit
# ---------------------------------------------------------------------------
log "Writing $ENV_FILE"
cat >"$ENV_FILE" <<EOF
PAPERCLIP_DEPLOYMENT_MODE=authenticated
PAPERCLIP_DEPLOYMENT_EXPOSURE=public
PAPERCLIP_AUTH_PUBLIC_BASE_URL=${PUBLIC_URL}
PAPERCLIP_ALLOWED_HOSTNAMES=${DOMAIN}
PATH=${USER_PATH}
EOF
chown "$RUN_USER:$RUN_USER" "$ENV_FILE"
chmod 600 "$ENV_FILE"

log "Writing $UNIT_FILE"
cat >"$UNIT_FILE" <<EOF
[Unit]
Description=Paperclip control plane
After=network-online.target
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
  cp "$CADDYFILE" "${CADDYFILE}.bak.$(date +%Y%m%d-%H%M%S)"
  cat >>"$CADDYFILE" <<EOF

${DOMAIN} {
    reverse_proxy 127.0.0.1:${PORT}
}
EOF
  if ! caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
    LATEST_BAK="$(ls -t "${CADDYFILE}".bak.* | head -n1)"
    cp "$LATEST_BAK" "$CADDYFILE"
    die "Caddyfile failed validation — restored $LATEST_BAK"
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
[[ $HTTPS_OK -eq 1 ]] && ok "$PUBLIC_URL is live" \
  || warn "HTTPS not answering yet — check: journalctl -u caddy -f"

# ---------------------------------------------------------------------------
# Firewall sanity
# ---------------------------------------------------------------------------
if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -Eq "^${PORT}\b"; then
  warn "UFW has a rule for port $PORT — remove it so only Caddy (80/443) faces the internet"
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
EOF
if [[ -n "$INVITE_URL" ]]; then
  echo " Invite:   ${INVITE_URL}"
  echo "           Open this on your phone to create your login."
else
  echo " Invite:   not generated (an owner may already exist). To create one:"
  echo "           sudo -iu ${RUN_USER} bash -c 'set -a; . ~/paperclip.env; set +a; npx paperclipai auth bootstrap-ceo --force'"
fi
cat <<EOF

 BACK UP THIS FILE OFF THE VPS (encrypts every stored secret):
   ${INSTANCE_DIR}/secrets/master.key

 Useful commands:
   journalctl -u ${SERVICE} -f              # logs
   sudo systemctl restart ${SERVICE}        # restart
   sudo -iu ${RUN_USER} npx paperclipai doctor
=============================================================
EOF
