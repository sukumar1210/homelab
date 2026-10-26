# homelab

The machine: how node-01 is laid out, what it needs, and the services that are the machine's own. One command manages
all of it:

```
~/sources/homelab/homelab              # status of everything; exit 1 if anything is wrong
~/sources/homelab/homelab node setup   # make the machine ready (the /srv layout, tools, docker group, linger)
~/sources/homelab/homelab <component> install|remove|status
```

## What this repository owns

| | What | Command |
|---|---|---|
| **Layout** | `/srv/sources` (code checkouts), `/srv/ops` (runtime state), `/srv/data` (data), each owned by you, linked as `~/sources`, `~/ops`, `~/data` | `homelab node check` / `setup` |
| **Tools** | git, make, python3, curl, jq, gawk, docker, git-lfs | `homelab node setup` installs what is missing (apt) |
| **Settings** | you in the `docker` group; linger, so user services run while logged out and after a reboot | `homelab node setup` |
| `power-logger` | whole-system power and energy log, `/srv/data/power/` (`bin/power-logger-ctl.sh`) | `homelab power-logger install` |
| `mdns-bridge` | answers mDNS queries by unicast, for routers that do not forward multicast wired-to-Wi-Fi (`bin/mdns-bridge-ctl.sh`) | `homelab mdns-bridge install` |
| `nextboot` | queues the current OS as the next EFI boot (`bin/setup-nextboot.sh`) | `homelab nextboot install` |
| `statusline` | the Claude Code status line ([claude-code/README.md](claude-code/README.md)) | `homelab statusline install` |

`homelab status` checks more than "is it active": for each unit it checks that the file the unit runs **exists and is
this checkout's**. After the move to `/srv/sources`, `mdns-unicast-bridge.service` still ran
`/home/sukumar/bin/service-scripts/mdns-unicast-bridge.py`, which no longer existed, and restarted every few seconds
with nothing reporting it. `homelab <component> install` rewrites the unit from the current checkout. The old
per-component scripts still work on their own; with no argument they show their menu.

## Projects on this node

Each deploys itself from its own repository. This repository only prepares the machine they run on, and never
installs or restarts them.

| Project | Checkout | Set up / check |
|---|---|---|
| algo-trading (the paper runtime, its OpenAlgo container, the deploy pipeline and its runner) | `/srv/sources/algo-trading` | `deploy/setup_node.sh` |
| market-recorder (the tick recorder and the data collectors) | `/srv/sources/market-recorder` | `make install`, `make status` |

Run `homelab node setup` first: both of them check for what it provides (docker, linger, the layout) and refer back
here.
