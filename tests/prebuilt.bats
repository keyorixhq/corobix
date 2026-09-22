#!/usr/bin/env bats
# Tests for FUZZ_PREBUILT mode's prebuilt_* functions in fuzz-runner.sh,
# especially the build-failure fallback (Part 2, item 3): a bad commit must
# never crash-loop the rig, and must never lose the last good generation.
# These actually invoke the Go toolchain against small fixture modules — slower
# than the pure-bash tests in runner.bats, but the thing under test IS
# `go test -c` / `-test.list` behavior, so a real build is the only honest test.

setup() {
  FUZZ_RUNNER_LIB=1 source "${BATS_TEST_DIRNAME}/../fuzz-runner.sh"
  MODULE_DIR="${BATS_TEST_TMPDIR}/mod"
  LOG_DIR="${BATS_TEST_TMPDIR}/logs"
  PREBUILT_DIR="${BATS_TEST_TMPDIR}/prebuilt"
  mkdir -p "$LOG_DIR"
  rm -rf "$MODULE_DIR" "$PREBUILT_DIR"
  mkdir -p "$MODULE_DIR/pkgA"
  cat >"$MODULE_DIR/go.mod" <<'EOF'
module fixture

go 1.21
EOF
  : >"$MODULE_DIR/go.sum"
  cat >"$MODULE_DIR/pkgA/a.go" <<'EOF'
package pkga

func Add(a, b int) int { return a + b }
EOF
  cat >"$MODULE_DIR/pkgA/a_fuzz_test.go" <<'EOF'
package pkga

import "testing"

func FuzzAdd(f *testing.F) {
	f.Add(1, 2)
	f.Fuzz(func(t *testing.T, a, b int) { _ = Add(a, b) })
}
EOF
  cd "$MODULE_DIR" || exit 1   # prebuilt_build/prebuilt_ensure run `go list`/`go test -c`
                                # relative to cwd, exactly as main() does after its own cd
}

# add_broken_pkgB -> a second package that fails to compile (undefined symbol),
# but still looks like a fuzz-target candidate to the grep pre-filter (has a
# func Fuzz* in a _test.go file) so prebuilt_build actually attempts it.
add_broken_pkgB() {
  mkdir -p "$MODULE_DIR/pkgB"
  cat >"$MODULE_DIR/pkgB/b.go" <<'EOF'
package pkgb

func Broken() int { return undefinedSymbol }
EOF
  cat >"$MODULE_DIR/pkgB/b_fuzz_test.go" <<'EOF'
package pkgb

import "testing"

func FuzzBroken(f *testing.F) {
	f.Fuzz(func(t *testing.T, x int) { _ = x })
}
EOF
}

@test "prebuilt_key falls back to a content hash outside git, and changes when source changes" {
  run prebuilt_key
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9a-f]{64}$ ]]
  first="$output"
  echo '// touch' >>"$MODULE_DIR/pkgA/a.go"
  run prebuilt_key
  [ "$output" != "$first" ]
}

@test "prebuilt_build succeeds for a clean module: manifest, binary, and target list" {
  run prebuilt_build "sha1"
  [ "$status" -eq 0 ]
  [ -f "$PREBUILT_DIR/sha1/.ok" ]
  [ -x "$PREBUILT_DIR/sha1/fixture_pkgA.test" ]
  grep -qF "FuzzAdd" "$PREBUILT_DIR/sha1/fixture_pkgA.targets"
  grep -qF "$(printf 'fixture/pkgA\tfixture_pkgA\t')" "$PREBUILT_DIR/sha1/manifest.tsv"
}

@test "prebuilt_ensure: bootstrap build failure falls back to classic discovery, never crashes" {
  add_broken_pkgB
  FUZZ_PREBUILT=1
  run prebuilt_ensure
  [ "$status" -eq 1 ]
  [ -z "$PREBUILT_ACTIVE_SHA" ]
  # No generation was ever promoted for a failed build.
  run bash -c "ls '$PREBUILT_DIR' 2>/dev/null | grep -v '^\.building-'"
  [ -z "$output" ]
  run discover_targets
  # discover()'s own exit status was never a meaningful contract (its real
  # caller only ever consumes its output via `mapfile < <(...)`) — only the
  # OUTPUT matters here: pkgA's target still lists via the classic fallback,
  # pkgB's broken one silently contributes nothing (same as it always has).
  [[ "$output" == *"fixture/pkgA|FuzzAdd"* ]]
  [[ "$output" != *"FuzzBroken"* ]]
}

@test "prebuilt_ensure: a build failure on a NEW commit keeps the previous good generation" {
  FUZZ_PREBUILT=1
  prebuilt_ensure   # NOT `run` — the side effect (setting PREBUILT_ACTIVE_SHA) must
                     # persist in this shell, which `run`'s subshell would discard.
  good_sha="$PREBUILT_ACTIVE_SHA"
  [ -n "$good_sha" ]
  [ -x "$PREBUILT_DIR/$good_sha/fixture_pkgA.test" ]

  add_broken_pkgB   # changes the content key -> a rebuild will be attempted and fail
  rc=0; prebuilt_ensure || rc=$?   # bare call again — see the note above
  [ "$rc" -eq 1 ]
  # Sticky: still pointing at the last generation that actually built.
  [ "$PREBUILT_ACTIVE_SHA" = "$good_sha" ]
  [ -f "$PREBUILT_DIR/$good_sha/.ok" ]
  [ -x "$PREBUILT_DIR/$good_sha/fixture_pkgA.test" ]

  run prebuilt_list_targets
  [ "$status" -eq 0 ]
  [[ "$output" == *"fixture/pkgA|FuzzAdd"* ]]
}

@test "prebuilt_prune keeps only the 2 most recently built generations" {
  run prebuilt_build "sha1"; [ "$status" -eq 0 ]
  sleep 1.1   # ensure a distinct, later mtime for the next generation
  run prebuilt_build "sha2"; [ "$status" -eq 0 ]
  sleep 1.1
  run prebuilt_build "sha3"; [ "$status" -eq 0 ]
  PREBUILT_ACTIVE_SHA=sha3
  prebuilt_prune
  [ -d "$PREBUILT_DIR/sha3" ]
  [ -d "$PREBUILT_DIR/sha2" ]
  [ ! -d "$PREBUILT_DIR/sha1" ]
}

@test "run_slice execs the prebuilt binary directly when a generation covers the package" {
  FUZZ_PREBUILT=1
  prebuilt_ensure
  [ -n "$PREBUILT_ACTIVE_SHA" ]
  PARALLEL=1
  run run_slice "fixture/pkgA" "FuzzAdd" "1s"
  [ "$status" -eq 0 ]
}

@test "run_slice falls back to go test when FUZZ_PREBUILT is off (default, unchanged)" {
  FUZZ_PREBUILT=0
  PARALLEL=1
  run run_slice "fixture/pkgA" "FuzzAdd" "1s"
  [ "$status" -eq 0 ]
}
