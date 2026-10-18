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
