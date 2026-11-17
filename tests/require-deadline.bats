#!/usr/bin/env bats
# Tests for scripts/require-deadline.sh — the per-input-deadline lint.
# The lint is pure bash/awk/grep, so these need no Go toolchain.

SCRIPT="${BATS_TEST_DIRNAME}/../scripts/require-deadline.sh"

# mk_helper <moduledir> [budget]  — write a conforming withinDeadline helper.
mk_helper() {
	local budget="${2:-2 * time.Second}"
	cat > "$1/helper_test.go" <<EOF
package fixture
import ("testing"; "time")
const perInputDeadline = $budget
func withinDeadline(t *testing.T, fn func()) {
	t.Helper()
	done := make(chan struct{})
	go func() { defer close(done); fn() }()
	if _, ok, _ := Wait(done, perInputDeadline); !ok {
		t.Fatalf("exceeded %s", perInputDeadline)
	}
}
EOF
}

# mk_module — fresh fixture module dir under the test tmpdir, echoes ROOT.
mk_module() {
	local root="${BATS_TEST_TMPDIR}/root"
	rm -rf "$root"; mkdir -p "$root/m"
	printf 'module fixture\ngo 1.25\n' > "$root/m/go.mod"
	echo "$root"
}

@test "real repo targets all enforce the deadline" {
	run bash "$SCRIPT" "${BATS_TEST_DIRNAME}/../targets"
	[ "$status" -eq 0 ]
	[[ "$output" == *"OK — all fuzz targets enforce the per-input deadline"* ]]
}

@test "flags a Fuzz target that does not wrap its body" {
	root="$(mk_module)"; mk_helper "$root/m"
	cat > "$root/m/a_test.go" <<'GO'
package fixture
import "testing"
func FuzzGood(f *testing.F) {
	f.Fuzz(func(t *testing.T, d []byte) { withinDeadline(t, func() { _ = len(d) }) })
}
func FuzzBad(f *testing.F) {
	f.Fuzz(func(t *testing.T, d []byte) { _ = len(d) })
}
GO
	run bash "$SCRIPT" "$root"
	[ "$status" -eq 1 ]
	[[ "$output" == *"FAIL  FuzzBad"* ]]
	[[ "$output" == *"ok    FuzzGood"* ]]
}

@test "accepts an unwrapped target that carries the opt-out marker" {
	root="$(mk_module)"; mk_helper "$root/m"
	cat > "$root/m/a_test.go" <<'GO'
package fixture
import "testing"
func FuzzGood(f *testing.F) {
	f.Fuzz(func(t *testing.T, d []byte) { withinDeadline(t, func() { _ = len(d) }) })
}
func FuzzExempt(f *testing.F) {
	//fuzzlint:no-deadline: replay-only smoke target, does no parsing
	f.Fuzz(func(t *testing.T, d []byte) { _ = len(d) })
}
GO
	run bash "$SCRIPT" "$root"
	[ "$status" -eq 0 ]
	[[ "$output" == *"opt   FuzzExempt"* ]]
}

@test "flags budget drift away from the uniform 2s" {
	root="$(mk_module)"; mk_helper "$root/m" "2 * time.Minute"
	cat > "$root/m/a_test.go" <<'GO'
package fixture
import "testing"
func FuzzGood(f *testing.F) {
	f.Fuzz(func(t *testing.T, d []byte) { withinDeadline(t, func() { _ = len(d) }) })
}
GO
	run bash "$SCRIPT" "$root"
	[ "$status" -eq 1 ]
	[[ "$output" == *"uniform budget"* ]]
}

@test "flags a module whose helper is missing entirely" {
	root="$(mk_module)"   # no mk_helper
	cat > "$root/m/a_test.go" <<'GO'
package fixture
import "testing"
func FuzzGood(f *testing.F) {
	f.Fuzz(func(t *testing.T, d []byte) { withinDeadline(t, func() { _ = len(d) }) })
}
GO
	run bash "$SCRIPT" "$root"
	[ "$status" -eq 1 ]
	[[ "$output" == *"canonical withinDeadline signature not found"* ]]
}

@test "exits 2 when ROOT contains no fuzz targets" {
	root="$(mk_module)"   # module exists but defines no Fuzz* funcs
	run bash "$SCRIPT" "$root"
	[ "$status" -eq 2 ]
	[[ "$output" == *"no fuzz targets found"* ]]
}

@test "exits 2 when ROOT is not a directory" {
	run bash "$SCRIPT" "${BATS_TEST_TMPDIR}/does-not-exist"
	[ "$status" -eq 2 ]
}
