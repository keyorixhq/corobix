#!/usr/bin/env bats
# Tests for scripts/sync-stall.sh — the check that every copy of the stall monitor is identical.

SCRIPT="${BATS_TEST_DIRNAME}/../scripts/sync-stall.sh"

@test "real repo: every module copy matches shared/stall.go.body" {
	run bash "$SCRIPT" --check
	[ "$status" -eq 0 ]
	[[ "$output" != *FAIL* ]]
}

@test "a drifted module copy is reported and fails the check" {
	f="${BATS_TEST_DIRNAME}/../targets/libs/stall_test.go"
	cp "$f" "$BATS_TEST_TMPDIR/orig"
	echo "// drift" >> "$f"
	run bash "$SCRIPT" --check
	cp "$BATS_TEST_TMPDIR/orig" "$f"
	[ "$status" -eq 1 ]
	[[ "$output" == *"FAIL  targets/libs/stall_test.go differs"* ]]
}

@test "an external copy is compared after its package line, ignoring any header" {
	body="${BATS_TEST_DIRNAME}/../shared/stall.go.body"
	{ echo "// some header"; echo "package other"; cat "$body"; } > "$BATS_TEST_TMPDIR/good.go"
	run bash "$SCRIPT" --check "$BATS_TEST_TMPDIR/good.go"
	[ "$status" -eq 0 ]
	{ echo "package other"; cat "$body"; echo "var x = 1"; } > "$BATS_TEST_TMPDIR/bad.go"
	run bash "$SCRIPT" --check "$BATS_TEST_TMPDIR/bad.go"
	[ "$status" -eq 1 ]
	[[ "$output" == *"bad.go differs"* ]]
}
