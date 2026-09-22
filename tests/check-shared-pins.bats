#!/usr/bin/env bats
# Tests for scripts/check-shared-pins.sh — the shared-module pin-drift check.
# Hermetic: KEYORIX_GOMOD_FILE points at a fixture go.mod instead of cloning,
# so these need no network and no Go toolchain.

SCRIPT="${BATS_TEST_DIRNAME}/../scripts/check-shared-pins.sh"

# mk_root — fresh fixture ROOT (a "targets/m" module) plus a fixture keyorix
# go.mod, both under the test tmpdir. Echoes "ROOT<TAB>KEYORIX_GOMOD".
mk_root() {
	local root="${BATS_TEST_TMPDIR}/root"
	rm -rf "$root"
	mkdir -p "$root/m"
	cat >"$root/m/go.mod" <<EOF
module fixture

go 1.27

require (
	github.com/foo/bar v1.0.0
	github.com/only/harness v9.9.9
)
EOF
	cat >"${BATS_TEST_TMPDIR}/keyorix-go.mod" <<EOF
module github.com/keyorixhq/keyorix

go 1.27

require (
	github.com/foo/bar v1.0.0
	github.com/only/keyorix v3.3.3
)
EOF
	printf '%s\t%s\n' "$root" "${BATS_TEST_TMPDIR}/keyorix-go.mod"
}

@test "clean when the harness pin matches keyorix" {
	IFS=$'\t' read -r root kgomod < <(mk_root)
	KEYORIX_GOMOD_FILE="$kgomod" run bash "$SCRIPT" "$root"
	[ "$status" -eq 0 ]
	[[ "$output" == *"ok    github.com/foo/bar @ v1.0.0"* ]]
	[[ "$output" == *"OK — every module shared"* ]]
}

@test "flags drift when the harness pin is downgraded away from keyorix" {
	IFS=$'\t' read -r root kgomod < <(mk_root)
	sed -i.bak 's/github.com\/foo\/bar v1.0.0/github.com\/foo\/bar v0.9.0/' "$root/m/go.mod"
	KEYORIX_GOMOD_FILE="$kgomod" run bash "$SCRIPT" "$root"
	[ "$status" -eq 1 ]
	[[ "$output" == *"FAIL  github.com/foo/bar: harness has v0.9.0, keyorix main has v1.0.0 (undocumented drift)"* ]]
}

@test "passes again once the downgraded pin is restored" {
	IFS=$'\t' read -r root kgomod < <(mk_root)
	sed -i.bak 's/github.com\/foo\/bar v1.0.0/github.com\/foo\/bar v0.9.0/' "$root/m/go.mod"
	KEYORIX_GOMOD_FILE="$kgomod" run bash "$SCRIPT" "$root"
	[ "$status" -eq 1 ]
	sed -i.bak 's/github.com\/foo\/bar v0.9.0/github.com\/foo\/bar v1.0.0/' "$root/m/go.mod"
	KEYORIX_GOMOD_FILE="$kgomod" run bash "$SCRIPT" "$root"
	[ "$status" -eq 0 ]
}

@test "a reviewed allowlist entry covers a divergent pin" {
	IFS=$'\t' read -r root kgomod < <(mk_root)
	sed -i.bak 's/github.com\/foo\/bar v1.0.0/github.com\/foo\/bar v0.9.0/' "$root/m/go.mod"
	printf 'github.com/foo/bar\tv0.9.0\tdeliberately fuzzing upstream latest ahead of our bump\t2099-01-01\n' \
		>>"${BATS_TEST_DIRNAME}/../scripts/pin-drift-allowlist.tsv.bats-tmp"
	cp "${BATS_TEST_DIRNAME}/../scripts/pin-drift-allowlist.tsv" "${BATS_TEST_DIRNAME}/../scripts/pin-drift-allowlist.tsv.orig-bats"
	cat "${BATS_TEST_DIRNAME}/../scripts/pin-drift-allowlist.tsv.bats-tmp" >>"${BATS_TEST_DIRNAME}/../scripts/pin-drift-allowlist.tsv"
	KEYORIX_GOMOD_FILE="$kgomod" run bash "$SCRIPT" "$root"
	mv "${BATS_TEST_DIRNAME}/../scripts/pin-drift-allowlist.tsv.orig-bats" "${BATS_TEST_DIRNAME}/../scripts/pin-drift-allowlist.tsv"
	rm -f "${BATS_TEST_DIRNAME}/../scripts/pin-drift-allowlist.tsv.bats-tmp"
	[ "$status" -eq 0 ]
	[[ "$output" == *"info  github.com/foo/bar @ v0.9.0"* ]]
	[[ "$output" == *"reviewed through 2099-01-01"* ]]
}

@test "an allowlist entry past its review date still fails" {
	IFS=$'\t' read -r root kgomod < <(mk_root)
	sed -i.bak 's/github.com\/foo\/bar v1.0.0/github.com\/foo\/bar v0.9.0/' "$root/m/go.mod"
	cp "${BATS_TEST_DIRNAME}/../scripts/pin-drift-allowlist.tsv" "${BATS_TEST_DIRNAME}/../scripts/pin-drift-allowlist.tsv.orig-bats"
	printf 'github.com/foo/bar\tv0.9.0\tstale review, nobody re-checked\t2000-01-01\n' \
		>>"${BATS_TEST_DIRNAME}/../scripts/pin-drift-allowlist.tsv"
	KEYORIX_GOMOD_FILE="$kgomod" run bash "$SCRIPT" "$root"
	mv "${BATS_TEST_DIRNAME}/../scripts/pin-drift-allowlist.tsv.orig-bats" "${BATS_TEST_DIRNAME}/../scripts/pin-drift-allowlist.tsv"
	[ "$status" -eq 1 ]
	[[ "$output" == *"FAIL  github.com/foo/bar @ v0.9.0 (keyorix: v1.0.0): allowlist entry expired (review date 2000-01-01"* ]]
}

@test "a module only the harness requires (not shared with keyorix) is ignored" {
	IFS=$'\t' read -r root kgomod < <(mk_root)
	KEYORIX_GOMOD_FILE="$kgomod" run bash "$SCRIPT" "$root"
	[ "$status" -eq 0 ]
	[[ "$output" != *"only/harness"* ]]
}

@test "--warn-only reports drift but always exits 0" {
	IFS=$'\t' read -r root kgomod < <(mk_root)
	sed -i.bak 's/github.com\/foo\/bar v1.0.0/github.com\/foo\/bar v0.9.0/' "$root/m/go.mod"
	KEYORIX_GOMOD_FILE="$kgomod" run bash "$SCRIPT" --warn-only "$root"
	[ "$status" -eq 0 ]
	[[ "$output" == *"FAIL  github.com/foo/bar"* ]]
	[[ "$output" == *"WARNING — drift found above"* ]]
}

@test "exits 2 when ROOT is not a directory" {
	run bash "$SCRIPT" "${BATS_TEST_TMPDIR}/does-not-exist"
	[ "$status" -eq 2 ]
}

@test "exits 2 when KEYORIX_GOMOD_FILE does not exist" {
	IFS=$'\t' read -r root kgomod < <(mk_root)
	KEYORIX_GOMOD_FILE="${BATS_TEST_TMPDIR}/nope.mod" run bash "$SCRIPT" "$root"
	[ "$status" -eq 2 ]
}
