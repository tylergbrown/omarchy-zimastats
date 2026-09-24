#!/usr/bin/env python3
"""Status of the two thin-client NAS boxes on the LAN."""

from __future__ import annotations

import json
import socket
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

# Brown-02 is 192.168.1.24. Brown-01 is the other NAS host used on this LAN.
CLIENTS = (
    {"id": "brown-02", "name": "Brown-02", "host": "192.168.1.24", "user": "tylerbrown"},
    {"id": "brown-01", "name": "Brown-01", "host": "192.168.1.169", "user": "tylerbrown"},
)

REMOTE = r"""
import json, os, time

def snap():
    parts = [int(x) for x in open("/proc/stat").readline().split()[1:8]]
    idle = parts[3] + (parts[4] if len(parts) > 4 else 0)
    return idle, sum(parts)

def energy():
    path = "/sys/class/powercap/intel-rapl:0/energy_uj"
    try:
        return int(open(path).read())
    except OSError:
        return None

def human(n):
    size = float(max(0, n))
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if size < 1024 or unit == "TB":
            return f"{size:.0f} {unit}" if unit == "B" else f"{size:.1f} {unit}"
        size /= 1024
    return f"{size:.1f} TB"

def volume(path, name):
    try:
        stats = os.statvfs(path)
    except OSError:
        return None
    total = stats.f_blocks * stats.f_frsize
    used = (stats.f_blocks - stats.f_bfree) * stats.f_frsize
    if total <= 0:
        return None
    pct = int(round(used * 100 / total))
    return {"name": name, "text": f"{human(used)} / {human(total)} · {pct}%", "pct": pct, "fault": pct >= 90}

cpu_a, total_a = snap()
joules_a = energy()
clock_a = time.time()
time.sleep(0.25)
cpu_b, total_b = snap()
joules_b = energy()
clock_b = time.time()
delta = total_b - total_a
cpu = round((1 - (cpu_b - cpu_a) / delta) * 100, 1) if delta else None
power = None
if joules_a is not None and joules_b is not None and clock_b > clock_a:
    used = joules_b - joules_a
    if used < 0:
        try:
            used += int(open("/sys/class/powercap/intel-rapl:0/max_energy_range_uj").read())
        except OSError:
            used = 0
    power = round((used / 1e6) / (clock_b - clock_a), 1)
try:
    hostname = open("/etc/hostname").read().strip()
except OSError:
    hostname = ""
storage = [row for row in (
    volume("/DATA", "Data"),
    volume("/media/Archive", "Archive"),
    volume("/", "System"),
) if row]
meminfo = {}
for line in open("/proc/meminfo"):
    key, rest = line.split(":", 1)
    meminfo[key] = int(rest.strip().split()[0]) * 1024
mem_total = meminfo.get("MemTotal", 0)
mem_avail = meminfo.get("MemAvailable", meminfo.get("MemFree", 0))
mem_used = max(0, mem_total - mem_avail)
mem_pct = int(round(mem_used * 100 / mem_total)) if mem_total else 0
memory = {
    "text": f"{human(mem_used)} / {human(mem_total)} · {mem_pct}%",
    "pct": mem_pct,
    "fault": mem_pct >= 90,
}
print(json.dumps({
    "hostname": hostname,
    "cpu_pct": cpu,
    "power_w": power,
    "storage": storage,
    "memory": memory,
}))
"""


def emit(payload: dict) -> None:
    json.dump(payload, sys.stdout)
    sys.stdout.write("\n")


def ssh_key() -> str:
    for path in ("/home/tb/.ssh/id_ed25519", "/home/tyler/.ssh/id_ed25519"):
        try:
            with open(path, "rb"):
                return path
        except OSError:
            continue
    raise FileNotFoundError("ssh key")


def port_open(host: str, port: int, timeout: float = 1.5) -> bool:
    sock = socket.socket()
    sock.settimeout(timeout)
    try:
        sock.connect((host, port))
        return True
    except OSError:
        return False
    finally:
        sock.close()


def sample(host: str, user: str) -> dict | None:
    try:
        key = ssh_key()
    except FileNotFoundError:
        return None
    try:
        completed = subprocess.run(
            [
                "ssh",
                "-o", "IdentitiesOnly=yes",
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=3",
                "-i", key,
                f"{user}@{host}",
                "python3 -",
            ],
            input=REMOTE,
            check=False,
            capture_output=True,
            text=True,
            timeout=8,
        )
    except (subprocess.TimeoutExpired, OSError):
        return None
    if completed.returncode != 0:
        return None
    lines = (completed.stdout or "").strip().splitlines()
    if not lines:
        return None
    try:
        payload = json.loads(lines[-1])
    except json.JSONDecodeError:
        return None
    return payload if isinstance(payload, dict) else None


def one(client: dict) -> dict:
    host = client["host"]
    online = port_open(host, 80) or port_open(host, 22)
    reading = sample(host, client["user"]) if online else None
    name = client["name"]
    if reading and reading.get("hostname"):
        name = str(reading["hostname"])
    return {
        "id": client["id"],
        "name": name,
        "address": host,
        "status": "online" if online else "offline",
        "detail": host,
        "power_w": None if reading is None else reading.get("power_w"),
        "cpu_pct": None if reading is None else reading.get("cpu_pct"),
        "storage": [] if reading is None else (reading.get("storage") or []),
        "memory": None if reading is None else reading.get("memory"),
        "metrics": "ok" if reading else ("offline" if not online else "unavailable"),
    }


def do_restart(host: str, user: str) -> dict:
    allowed = {client["host"]: client["user"] for client in CLIENTS}
    if allowed.get(host) != user:
        return {"ok": False, "error": "unknown client"}
    try:
        key = ssh_key()
    except FileNotFoundError:
        return {"ok": False, "error": "ssh key missing"}
    try:
        completed = subprocess.run(
            [
                "ssh",
                "-o", "IdentitiesOnly=yes",
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=4",
                "-i", key,
                f"{user}@{host}",
                "sudo -n /usr/bin/systemctl reboot",
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=15,
        )
    except subprocess.TimeoutExpired:
        return {"ok": True, "host": host}
    except OSError as exc:
        return {"ok": False, "error": type(exc).__name__}
    detail = ((completed.stderr or "") + "\n" + (completed.stdout or "")).strip()
    if completed.returncode == 0:
        return {"ok": True, "host": host}
    if "password is required" in detail:
        return {"ok": False, "error": "a password is required to reboot this NAS"}
    last = detail.splitlines()[-1] if detail else f"exit {completed.returncode}"
    return {"ok": False, "error": last[:180]}


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "restart":
        host = sys.argv[2] if len(sys.argv) > 2 else ""
        user = sys.argv[3] if len(sys.argv) > 3 else "tylerbrown"
        emit(do_restart(host, user))
        return 0
    with ThreadPoolExecutor(max_workers=2) as pool:
        clients = list(pool.map(one, CLIENTS))
    emit({"clients": clients})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
