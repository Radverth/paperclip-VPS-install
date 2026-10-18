#!/usr/bin/env bash
# Logs Claude Code in on the VPS as the `bridge` user (using your Claude
# subscription), cleans up the earlier token attempt, restarts Paperclip and
# checks everything works.
#
# Run on your laptop:  bash setup-claude-paperclip.sh <vps-host-or-ip> [ssh-user]
# ssh-user defaults to root (needed to switch to `bridge` without a password).

set -euo pipefail

VPS_HOST="${1:-}"
VPS_USER="${2:-root}"
AGENT_USER="bridge"

if [ -z "$VPS_HOST" ]; then
  read -rp "VPS hostname or IP: " VPS_HOST
fi

TARGET="$VPS_USER@$VPS_HOST"

cat <<EOF

=== Step 1 of 2: sign Claude Code in as '$AGENT_USER' ===
Claude Code will open on the VPS. When it does:
  1. Type  /login  and press Enter
  2. Choose your Claude account (subscription), not an API key
  3. Open the link it shows in your laptop's browser and approve
  4. Paste the code back into the terminal
  5. Once it says you're logged in, type  /exit

Press Enter to continue...
EOF
read -r

ssh -t "$TARGET" "su - $AGENT_USER -c claude"

echo
echo "=== Step 2 of 2: verify login and restart Paperclip ==="

ssh "$TARGET" "su - $AGENT_USER -c 'bash -s'" <<'REMOTE'
set -u
export XDG_RUNTIME_DIR="/run/user/$(id -u)"

if [ -f "$HOME/.claude/.credentials.json" ]; then
  echo "[ok] Credentials file found"
else
  echo "[warn] No ~/.claude/.credentials.json - login may not have saved"
fi

# Remove the earlier token attempt so it can't override this login
SERVICE="$HOME/.config/systemd/user/paperclip.service"
if [ -f "$SERVICE" ] && grep -q '^EnvironmentFile=' "$SERVICE"; then
  sed -i '/^EnvironmentFile=/d' "$SERVICE"
  echo "[ok] Removed old token line from paperclip.service"
fi
rm -f "$HOME/.config/paperclip/env"

echo "Testing Claude Code (can take up to a minute)..."
if out=$(cd "$HOME" && timeout 120 claude -p "Reply with exactly: ok" 2>&1); then
  echo "[ok] Claude replied: $out"
else
  echo "[fail] Claude test failed:"
  echo "$out"
  exit 1
fi

echo "Restarting Paperclip..."
systemctl --user daemon-reload
systemctl --user restart paperclip
sleep 15

code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3100/api/health || true)
if [ "$code" = "200" ]; then
  echo "[ok] Paperclip is back up (health 200)"
else
  echo "[fail] Paperclip health returned '$code'. Recent logs:"
  journalctl --user -u paperclip -n 30 --no-pager
  exit 1
fi

echo
echo "All done. Re-run the CEO's task in Paperclip."
REMOTE
