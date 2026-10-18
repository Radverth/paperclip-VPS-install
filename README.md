# paperclip-VPS-install
## Claude Code login for agents

If Paperclip agents report they're logged out of Claude Code (Paperclip's own
"Connect account" needs a browser the VPS doesn't have), run this from your
laptop. It signs Claude Code in as the `bridge` user with your Claude
subscription, then restarts Paperclip and checks it's healthy:

```bash
bash scripts/setup-claude-login.sh YOUR-VPS-IP [ssh-user]
```

`ssh-user` defaults to `root`.

## Uninstall

Removes the Paperclip service, its Postgres container and data, all Paperclip
files and the Caddy block. Saves a final backup to `/root` first. Node, Docker,
Caddy, n8n, Bridge and the `bridge` user's Claude/Codex logins are left alone.

```bash
curl -fsSL https://raw.githubusercontent.com/Radverth/paperclip-VPS-install/main/uninstall-paperclip.sh -o uninstall-paperclip.sh
sudo DRY_RUN=1 bash uninstall-paperclip.sh   # preview
sudo bash uninstall-paperclip.sh             # remove
```

Skip the final backup with `sudo NO_BACKUP=1 bash uninstall-paperclip.sh`.
