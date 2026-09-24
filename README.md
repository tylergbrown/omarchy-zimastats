# Omarchy Zima Stats

Omarchy **bar widget** for Brown-01 and Brown-02 ZimaOS NAS boxes on the LAN.

Shows dual status dots on the bar, per-host **CPU throttle gauges**, **memory** usage bars, **storage donut pies**, and a double-confirm reboot over SSH.

- Plugin id: `tb.zima` (Omarchy install folder name)
- Repo: `omarchy-zimastats`
- Version: **1.2.0**

## Install

```bash
omarchy plugin add https://github.com/tylergbrown/omarchy-zimastats.git --enable --yes
```

If the chip does not appear:

```bash
omarchy-restart-shell
```

Update later:

```bash
omarchy plugin update tb.zima --yes
omarchy-restart-shell
```

## Settings

| Key | Default | Meaning |
|-----|---------|---------|
| `host` | `192.168.1.24` | Primary NAS address seed (Brown-02) |
| `sshUser` | `tylerbrown` | SSH user for metrics + reboot |
| `pollSec` | `15` | Status poll interval |

Defaults match the Brown LAN seats (Brown-02 `192.168.1.24`, Brown-01 `192.168.1.169`). Confirm SSH from the Omarchy machine:

```bash
ssh -o BatchMode=yes tylerbrown@192.168.1.24 true
ssh -o BatchMode=yes tylerbrown@192.168.1.169 true
```

The plugin uses `~/.ssh/id_ed25519` (or your agent) from the Omarchy machine.

## Files

- `manifest.json` — Omarchy plugin metadata and settings schema
- `Widget.qml` — bar chip + popup UI (CPU gauge, memory bar, storage pies)
- `status.py` — LAN/SSH metrics and reboot helpers

## Notes

- Restart is double-confirm and reboots that NAS host over SSH.
- Requires Omarchy / Quickshell bar widgets (`BarWidget`, `PopupCard`, `qs.Commons`, `qs.Ui`).
- v1.2.0 replaces Latency/Power tiles with storage pie chips and adds a CPU throttle gauge.
