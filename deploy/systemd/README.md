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

These four files are the source of truth for **these** rigs. For a **brand-new**
rig, start from [`../../templates/fuzz-rig.service.tmpl`](../../templates/fuzz-rig.service.tmpl):
it carries that shared baseline with the per-box knobs commented, as a starting
point to fill in and tune — not a renderer that reproduces the four above. Save
the result here as `<service>.service` so it too becomes tracked and deployable.

## Config lookup

`fuzz-runner.sh` reads its config from `$FUZZ_CONF`, else `$SCRIPT_DIR/fuzz.conf`
(the `fuzz.conf` beside the runner copy). Set `FUZZ_CONF` only when one runner
copy must serve a conf that is NOT beside it (the `libs-extra-fuzz` case). The
crash report sink is `REPORT_MODE` in that `fuzz.conf` (default `private`).

## Operate a rig with `deploy.sh`

[`../deploy.sh`](../deploy.sh) is the one command for all three rig operations;
each is human-gated and takes `--dry-run` to print the exact plan (ssh/scp/sudo)
without touching anything. Preview first — always.

```sh
deploy/deploy.sh --list                       # keyorix | dashdiag | libs-extra | libs
deploy/deploy.sh <rig>... | --all              # push THIS checkout's fuzz-runner.sh (no root)
deploy/deploy.sh --unit <rig>...               # install/reconcile the canonical unit (sudo on rig)
deploy/deploy.sh --bootstrap <rig>             # cold-start a fresh rig end to end (sudo on rig)
deploy/deploy.sh --dry-run <any of the above>  # print the plan, change nothing
```

- **runner push** (`<rig>`/`--all`) needs no root: it scp's the runner and bumps
  a marker in the rig's `fuzz.conf` to trip the runner's config-hash self-reload.
  It targets the path the *service* runs (`ExecStart`), so `libs-extra` correctly
  updates the runner copy it shares with `dashdiag`, not a private copy.
- **`--unit`** scripts the manual reconcile runbook below: scp the tracked unit,
  back up the old one, `install -m0644`, `daemon-reload`, `restart`, verify. It
  does **not** remove drop-ins — it lists any it finds so you decide.
- **`--bootstrap`** cold-starts one fresh rig: check go/git, make dirs, clone the
  module (git rigs) or expect an assembled tree (standalone), seed `fuzz.conf`
  from `examples/` *only if absent*, push the runner, install the unit, and
  `enable --now`. Run `--dry-run` first, then run it for real on the prepared box.

## Reconcile a rig to canonical (needs root / sudo on the rig)

`deploy.sh --unit <rig>` does the steps below for you; the manual runbook is kept
for the one-time drop-in removal (which `--unit` intentionally leaves to you) and
for when you want to run each step by hand.

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
