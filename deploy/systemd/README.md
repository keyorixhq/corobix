# Rig systemd units (canonical, tracked)

Every fuzz rig runs the **same** runner — `fuzz-runner.sh` in this repo. These
are the canonical systemd units, one per rig service. They are the source of
truth: a rig's installed `/etc/systemd/system/<svc>.service` should match the
file here (differences below are deliberate per-box facts, not architecture).

| Service | Box | User | Runner copy | Conf | Caps |
|---|---|---|---|---|---|
| `keyorix-fuzz` | vcd-keyorix-fuzz | andrei | `~/proj/fuzz-harness/fuzz-runner.sh` | `$SCRIPT_DIR/fuzz.conf` | CPUQuota 700%, MemoryMax 5500M |
| `dashdiag-fuzz` | vcd-dashdiag-fuzz | andrei | `~/proj/fuzz-harness/fuzz-runner.sh` | `$SCRIPT_DIR/fuzz.conf` | MemoryMax 3000M |
| `libs-extra-fuzz` | vcd-dashdiag-fuzz | andrei | `~/proj/fuzz-harness/fuzz-runner.sh` | `FUZZ_CONF=~/proj/libs-extra-fuzz/fuzz.conf` | MemoryMax 3000M |
| `libsfuzz` | pve01 | root | `/root/libs-fuzz/fuzz-runner.sh` | `$SCRIPT_DIR/fuzz.conf` | MemoryMax 12G |

Deliberate per-box differences: user (root on pve01), Go paths, `MemoryMax`
sized to each box's RAM, `CPUQuota` only where the box is shared, and
`FUZZ_CONF` only where one runner copy serves a second conf. Everything else is
identical: `Type=simple`, `ExecStart=<runner>`, `MemorySwapMax=0`,
`Restart`, journal logging, `WantedBy=multi-user.target`.

## Config lookup

`fuzz-runner.sh` reads its config from `$FUZZ_CONF`, else `$SCRIPT_DIR/fuzz.conf`
(the `fuzz.conf` beside the runner copy). Set `FUZZ_CONF` only when one runner
copy must serve a conf that is NOT beside it (the `libs-extra-fuzz` case). The
crash report sink is `REPORT_MODE` in that `fuzz.conf` (default `private`).

## Reconcile a rig to canonical (needs root / sudo on the rig)

`libs-extra-fuzz` and `libsfuzz` are already clean and match these files.
`keyorix-fuzz` and `dashdiag-fuzz` were migrated to the runner via a stack of
drop-ins (`.d/10-harness.conf` overriding a now-removed old-rig `ExecStart`,
`.d/memory.conf`, and `set-property` overrides under `system.control`). Fold
that into the canonical unit and drop the overrides. This is hygiene — the
service already runs `fuzz-runner.sh` via the drop-in, so there is no rush and
no functional change; it only makes the installed unit match this file.

From a checkout of this repo (e.g. your Mac), pick `<svc>` = `keyorix-fuzz` on
vcd-keyorix-fuzz, or `dashdiag-fuzz` on vcd-dashdiag-fuzz:

```sh
SVC=keyorix-fuzz            # or dashdiag-fuzz
RIG=vcd-keyorix-fuzz        # or vcd-dashdiag-fuzz
scp deploy/systemd/$SVC.service "$RIG:/tmp/$SVC.service"

ssh "$RIG" sudo bash -s "$SVC" <<'EOF'
set -euo pipefail
SVC="$1"; ts="$(date +%s)"
# 1. Back up current unit + drop-ins
cp -a "/etc/systemd/system/$SVC.service" "/root/$SVC.service.bak.$ts"
[ -d "/etc/systemd/system/$SVC.service.d" ] && cp -a "/etc/systemd/system/$SVC.service.d" "/root/$SVC.d.bak.$ts" || true
# 2. Install canonical unit
install -m0644 "/tmp/$SVC.service" "/etc/systemd/system/$SVC.service"
# 3. Drop the folded-in overrides
rm -f "/etc/systemd/system/$SVC.service.d/10-harness.conf" "/etc/systemd/system/$SVC.service.d/memory.conf"
rmdir "/etc/systemd/system/$SVC.service.d" 2>/dev/null || true
rm -rf "/etc/systemd/system.control/$SVC.service.d"
# 4. Reload + restart + verify
systemctl daemon-reload
systemctl restart "$SVC"
sleep 5
systemctl is-active "$SVC"
systemctl show "$SVC" -p ExecStart -p MemoryMax -p MemorySwapMax -p CPUQuotaPerSecUSec --value
EOF
```

Confirm the runner resumed (a `discovered N target(s)` then a `=== fuzzing …`
line in the rig's `rotation.log`). **Rollback**: copy `/root/$SVC.service.bak.<ts>`
back, restore the `.d` backup if any, `daemon-reload`, `restart`.

For `libs-extra-fuzz` / `libsfuzz` (already clean), the same `scp` +
`install` + `daemon-reload` makes the on-disk unit byte-match this file; no
drop-ins to remove. A restart is optional (the content is equivalent).
