#!/usr/bin/env bash
# Capture the full current unit definition + resolved env for a rig service,
# and save a timestamped backup of the unit + drop-ins for rollback.
set -uo pipefail
U="$1"   # service name without .service
TS="$(date -u +%Y%m%dT%H%M%SZ)"
BK="$HOME/fuzz-migrate-backup/$TS"
mkdir -p "$BK"
echo "=== systemctl cat $U ==="
systemctl cat "$U.service" 2>/dev/null | tee "$BK/$U.cat.txt"
echo "=== resolved Environment ==="
systemctl show "$U.service" -p Environment --value
echo "=== ExecStart / User / Mem ==="
systemctl show "$U.service" -p ExecStart -p User -p MemoryMax -p MainPID -p MemoryCurrent --value
echo "=== backup saved to: $BK ==="
# copy the raw unit file + any drop-ins
MAIN="$(systemctl show "$U.service" -p FragmentPath --value)"
[ -n "$MAIN" ] && cp -a "$MAIN" "$BK/" 2>/dev/null && echo "copied $MAIN"
for d in "/etc/systemd/system/$U.service.d" "/etc/systemd/system.control/$U.service.d"; do
  [ -d "$d" ] && cp -a "$d" "$BK/$(basename "$(dirname "$d")").dropins" 2>/dev/null && echo "copied $d"
done
ls -R "$BK"
