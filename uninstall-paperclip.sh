#!/usr/bin/env bash
# =============================================================================
# Paperclip uninstaller — reverses Radverth/paperclip-VPS-install
#
# Removes:
#   - systemd service `paperclip` (system unit, plus any old user unit for bridge)
#   - Docker container `paperclip_postgres` and volume `paperclip_pgdata`
#   - ~bridge/.paperclip, ~bridge/.paperclip.bak.*, ~bridge/paperclip.env,
#     ~bridge/.config/paperclip, Paperclip's npx cache
#   - the Caddy block for paperclip.n8ntom.duckdns.org
#
# Leaves alone: Node, Docker, Caddy itself, the bridge user, Claude Code / Codex
# logins, n8n, Bridge.
#
# By default it first saves a final backup (DB dump + instance folder incl.
# secrets/master.key) to /root/paperclip-final-backup-<date>.tar.gz.
#
# Usage (as your sudo user):
#   sudo bash uninstall-paperclip.sh
#   sudo NO_BACKUP=1 bash uninstall-paperclip.sh      # skip the final backup
#   sudo DRY_RUN=1 bash uninstall-paperclip.sh        # show what would happen
# =============================================================================
set -euo pipefail

DOMAIN="${DOMAIN:-paperclip.n8ntom.duckdns.org}"
RUN_USER="${RUN_USER:-bridge}"
CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
SERVICE="paperclip"
DB_CONTAINER="paperclip_postgres"
DB_VOLUME="paperclip_pgdata"
NO_BACKUP="${NO_BACKUP:-0}"
DRY_RUN="${DRY_RUN:-0}"
STAMP="$(date +%Y%m%d-%H%M%S)"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [[ "$DRY_RUN" == "1" ]]; then echo "  [dry-run] $*"; else eval "$@"; fi; }

[[ $EUID -eq 0 ]] || die "Run with sudo: sudo bash $0"
id "$RUN_USER" &>/dev/null || die "User '$RUN_USER' does not exist"
RUN_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"
RUN_UID="$(id -u "$RUN_USER")"
HAVE_DOCKER=0; command -v docker &>/dev/null && HAVE_DOCKER=1
container_exists() { [[ $HAVE_DOCKER -eq 1 ]] && docker ps -a --format '{{.Names}}' | grep -qx "$DB_CONTAINER"; }

[[ "$DRY_RUN" == "1" ]] && warn "DRY RUN — nothing will be changed"

# -----------------------------------------------------------------------------
# 1. Final backup
# -----------------------------------------------------------------------------
if [[ "$NO_BACKUP" != "1" ]]; then
  log "Saving a final backup"
  TMPB="$(mktemp -d)"
  if container_exists; then
    docker start "$DB_CONTAINER" >/dev/null 2>&1 || true
    sleep 3
    if docker exec "$DB_CONTAINER" pg_dump -U paperclip paperclip >"$TMPB/paperclip-db.sql" 2>/dev/null; then
      ok "Database dumped"
    else
      warn "Could not dump the database (continuing)"
    fi
  fi
  [[ -d "$RUN_HOME/.paperclip" ]] && cp -a "$RUN_HOME/.paperclip" "$TMPB/instance"
  [[ -f "$RUN_HOME/paperclip.env" ]] && cp -a "$RUN_HOME/paperclip.env" "$TMPB/"
  if [[ -n "$(ls -A "$TMPB")" ]]; then
    BACKUP="/root/paperclip-final-backup-$STAMP.tar.gz"
    run "tar -czf '$BACKUP' -C '$TMPB' . && chmod 600 '$BACKUP'"
    [[ "$DRY_RUN" == "1" ]] || ok "Backup: $BACKUP (delete it once you're sure)"
  else
    ok "Nothing to back up"
  fi
  rm -rf "$TMPB"
fi

# -----------------------------------------------------------------------------
# 2. Stop and remove the services
# -----------------------------------------------------------------------------
log "Stopping Paperclip"
if [[ -f "/etc/systemd/system/${SERVICE}.service" ]]; then
  run "systemctl disable --now '$SERVICE' 2>/dev/null || true"
  run "rm -f '/etc/systemd/system/${SERVICE}.service'"
  run "systemctl daemon-reload"
  run "systemctl reset-failed '$SERVICE' 2>/dev/null || true"
  ok "Removed system service"
else
  ok "No system service found"
fi

# Older attempt left a user-level unit for bridge (see setup-claude-login.sh)
USER_UNIT="$RUN_HOME/.config/systemd/user/${SERVICE}.service"
if [[ -f "$USER_UNIT" ]]; then
  run "sudo -u '$RUN_USER' XDG_RUNTIME_DIR=/run/user/$RUN_UID systemctl --user disable --now '$SERVICE' 2>/dev/null || true"
  run "rm -f '$USER_UNIT'"
  run "sudo -u '$RUN_USER' XDG_RUNTIME_DIR=/run/user/$RUN_UID systemctl --user daemon-reload 2>/dev/null || true"
  ok "Removed user service"
fi

# Any stray processes
run "pkill -TERM -u '$RUN_USER' -f 'paperclipai' 2>/dev/null || true"
run "pkill -TERM -u '$RUN_USER' -f '$RUN_HOME/.paperclip' 2>/dev/null || true"
[[ "$DRY_RUN" == "1" ]] || sleep 2
run "pkill -KILL -u '$RUN_USER' -f 'paperclipai' 2>/dev/null || true"
ok "No Paperclip processes left"

# -----------------------------------------------------------------------------
# 3. Database container
# -----------------------------------------------------------------------------
log "Removing Postgres container"
if container_exists; then
  run "docker rm -f '$DB_CONTAINER' >/dev/null"
  ok "Removed $DB_CONTAINER"
else
  ok "No container found"
fi
if [[ $HAVE_DOCKER -eq 1 ]] && docker volume inspect "$DB_VOLUME" &>/dev/null; then
  run "docker volume rm '$DB_VOLUME' >/dev/null"
  ok "Removed volume $DB_VOLUME"
fi

# -----------------------------------------------------------------------------
# 4. Files
# -----------------------------------------------------------------------------
log "Removing Paperclip files"
for p in "$RUN_HOME/.paperclip" "$RUN_HOME"/.paperclip.bak.* "$RUN_HOME/paperclip.env" "$RUN_HOME/.config/paperclip"; do
  [[ -e "$p" ]] || continue
  run "rm -rf '$p'"
  ok "Removed $p"
done
# npx cache entries that contain paperclipai
if [[ -d "$RUN_HOME/.npm/_npx" ]]; then
  while IFS= read -r d; do
    run "rm -rf '$d'"
    ok "Removed npx cache $(basename "$d")"
  done < <(find "$RUN_HOME/.npm/_npx" -mindepth 1 -maxdepth 1 -type d -exec test -d '{}/node_modules/paperclipai' ';' -print)
fi
run "rm -f /tmp/paperclip-onboard.*.log"

# -----------------------------------------------------------------------------
# 5. Caddy
# -----------------------------------------------------------------------------
log "Removing Caddy block for $DOMAIN"
if [[ -f "$CADDYFILE" ]] && grep -Eq "^[[:space:]]*${DOMAIN//./\\.}[[:space:]]*\{" "$CADDYFILE"; then
  CADDY_BAK="${CADDYFILE}.bak.uninstall.$STAMP"
  NEW="$(mktemp)"
  awk -v dom="$DOMAIN" '
    BEGIN { skip = 0; depth = 0 }
    {
      line = $0
      if (!skip) {
        t = line; sub(/^[ \t]+/, "", t)
        if (index(t, dom) == 1) {
          rest = substr(t, length(dom) + 1); sub(/^[ \t]+/, "", rest)
          if (substr(rest, 1, 1) == "{") { skip = 1; depth = 0 }
        }
      }
      if (skip) {
        o = gsub(/\{/, "{", line); c = gsub(/\}/, "}", line)
        depth += o - c
        if (depth <= 0) { skip = 0 }
        next
      }
      print $0
    }' "$CADDYFILE" | cat -s >"$NEW"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "  [dry-run] would apply this change to $CADDYFILE:"
    diff -u "$CADDYFILE" "$NEW" || true
  else
    cp "$CADDYFILE" "$CADDY_BAK"
    cat "$NEW" >"$CADDYFILE"
    if caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
      systemctl reload caddy
      ok "Removed block and reloaded Caddy (backup: $CADDY_BAK)"
    else
      cp "$CADDY_BAK" "$CADDYFILE"
      die "Edited Caddyfile failed validation — restored $CADDY_BAK. Remove the $DOMAIN block by hand."
    fi
  fi
  rm -f "$NEW"
else
  ok "No Caddy block found"
fi

# -----------------------------------------------------------------------------
# 6. Firewall
# -----------------------------------------------------------------------------
if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -Eq '^(3100|5433)\b'; then
  warn "UFW has a rule for port 3100 or 5433 — remove it: sudo ufw status numbered"
fi

cat <<EOF

=============================================================
 Paperclip removed
=============================================================
 Kept: Node, Docker, Caddy, the '$RUN_USER' user and its Claude/Codex logins.
 Optional, by hand:
   - Delete the GitHub repo Radverth/paperclip-VPS-install
   - Remove 'paperclip' from DuckDNS if you set it up as its own name
   - Delete the final backup in /root once you're sure
=============================================================
EOF
