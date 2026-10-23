#!/usr/bin/env python3
"""Select the oldest installed iOS simulator for the UI compatibility checks."""
import json
import re
import subprocess
import sys


def main():
    data = json.loads(subprocess.check_output(
        ["xcrun", "simctl", "list", "devices", "available", "--json"], text=True
    ))
    candidates = []
    for runtime, devices in data["devices"].items():
        match = re.search(r"\.iOS-(\d+)-(\d+)(?:-(\d+))?$", runtime)
        if not match:
            continue
        version = tuple(int(part or 0) for part in match.groups())
        if version < (16, 0, 0):
            continue
        for device in devices:
            if device.get("isAvailable") and device["name"].startswith("iPhone"):
                candidates.append((version, "Max" not in device["name"], device["name"], device["udid"]))
    if not candidates:
        raise SystemExit("No available iPhone simulator (iOS 16+) is installed")
    version, _, name, udid = min(candidates)
    description = f"{name}, iOS {'.'.join(map(str, version))}, {udid}"
    print(f"UI regression simulator: {description}", file=sys.stderr)
    print(udid)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
