#!/usr/bin/env bats

# Integration tests for the overlay.sync=filesystem feature in CRI-O.
#
# overlay.sync=filesystem is an opt-in containers-storage/CRI-O option that
# calls syncfs() before committing layer metadata to disk.  When enabled,
# a hard process kill (or kernel crash) mid-pull leaves the store in a
# deterministically recoverable state:
#
#   1.  The incompleteFlag ("incomplete"=true in layers.json) is written
#       *before* any layer data is extracted — so it is always present on disk
#       even after a SIGKILL.
#   2.  syncfs() is called *after* all layer data is written but *before* the
#       final metadata commit that clears the flag — guaranteeing that if the
#       flag is absent, all layer data is durable.
#
# On restart, containers/storage load() detects incomplete-flagged layers and
# discards them, leaving the store clean without any escalated repair. That
# cleanup is generic containers/storage behavior — it runs the same with or
# without sync=filesystem — so it is covered separately below and is not
# itself evidence that sync=filesystem did anything.
#
# Test coverage:
#   - overlay.sync=filesystem actually triggers syncfs() while committing a
#     pulled layer (direct syscall-level verification, on/off pair).
#   - A pull done under sync=filesystem survives a CRI-O restart.
#   - containers/storage removes an incomplete-flagged layer on startup
#     (generic cleanup, independent of sync mode).
#   - Pull-time overhead of sync=filesystem, gated behind SYNCFS_BENCHMARK=1
#     (informational only; this VM's noise floor is larger than the signal).
#   - Negative control — guards against a regression in CRI-O's unrelated
#     unclean-shutdown repair path when the feature is off (does not, by
#     itself, prove sync=filesystem does anything; see the test's comment).
#

load helpers

# Large multi-layer image
SYNCFS_IMAGE="quay.io/crio/fedora-crio-ci:latest"

function setup() {
	setup_test
	# Enable overlay.sync=filesystem for every test in this file.
	# STORAGE_OPTIONS is picked up by setup_crio(); tests that need the
	# negative-control path override it locally before calling setup_crio.
	STORAGE_OPTIONS="${STORAGE_OPTIONS:+$STORAGE_OPTIONS }--storage-opt overlay.sync=filesystem"
}

function teardown() {
	cleanup_test
}

# ── syncfs() actually happens ────────────────────────────────────────────────
#
# Direct syscall-level proof that the option takes effect: strace the CRI-O
# process for syncfs(2) while it commits a freshly pulled layer, with the
# option on and off. This is the one test in this file that would actually
# go red if the option stopped being parsed or stopped calling syncfs().
@test "overlay.sync=filesystem calls syncfs() while committing a pulled layer" {
	setup_crio
	start_crio_no_setup

	# fedora-crio-ci is preloaded by setup_crio; remove it first so the pull
	# below actually writes layers instead of reusing what's already there.
	crictl rmi "$SYNCFS_IMAGE" 2>/dev/null || true

	strace -f -qq -e trace=syncfs -p "$CRIO_PID" -o "$TESTDIR/strace.out" &
	local strace_pid=$!
	sleep 1

	crictl pull "$SYNCFS_IMAGE"

	kill "$strace_pid" 2>/dev/null || true
	wait "$strace_pid" 2>/dev/null || true

	grep -q 'syncfs(' "$TESTDIR/strace.out"
}

@test "without overlay.sync=filesystem, no syncfs() calls occur while committing a pulled layer" {
	STORAGE_OPTIONS="" setup_crio
	start_crio_no_setup

	crictl rmi "$SYNCFS_IMAGE" 2>/dev/null || true

	strace -f -qq -e trace=syncfs -p "$CRIO_PID" -o "$TESTDIR/strace.out" &
	local strace_pid=$!
	sleep 1

	crictl pull "$SYNCFS_IMAGE"

	kill "$strace_pid" 2>/dev/null || true
	wait "$strace_pid" 2>/dev/null || true

	! grep -q 'syncfs(' "$TESTDIR/strace.out"
}

#
# With sync=filesystem, the final metadata commit (clearing incompleteFlag) is
# preceded by syncfs().  A clean restart must find the layer intact, load it
# from the same on-disk state, and report the same image ID.
@test "images pulled with sync=filesystem survive a CRI-O restart" {
	setup_crio
	start_crio_no_setup

	# Force a real pull: the image is preloaded by setup_crio, so remove it
	# first — otherwise this reuses already-committed layers and never
	# exercises the sync=filesystem write path at all.
	crictl rmi "$SYNCFS_IMAGE" 2>/dev/null || true
	crictl pull "$SYNCFS_IMAGE"
	local image_id
	image_id=$(crictl images -q "$SYNCFS_IMAGE")
	[ -n "$image_id" ]

	# Graceful stop + restart from the same on-disk storage directory.
	# Does NOT call setup_crio again so no config is regenerated.
	stop_crio_no_clean ""
	start_crio_no_setup

	local image_id_after
	image_id_after=$(crictl images -q "$SYNCFS_IMAGE")
	[ "$image_id_after" = "$image_id" ]
}

# ── Incomplete-layer cleanup on startup ──────────────────────────────────────
#
# A hard kill (SIGKILL / kernel crash) mid-pull can leave containers/storage
# with a layer whose incompleteFlag is still "true" in layers.json. On next
# startup, load() must detect and discard any incomplete-flagged layer,
# logging "Found incomplete layer". This cleanup is generic containers/
# storage behavior that runs identically regardless of sync mode — it does
# not, by itself, demonstrate anything about sync=filesystem. It's kept here
# as a regression guard for the mechanism that sync=filesystem's durability
# guarantee relies on (see the header comment above).
#
# Racing a real "kill mid-pull" against a timer is flaky in this environment:
# pull timing isn't reliable enough to land the kill consistently mid-write
# (see the preloaded-vs-fresh-pull timing note on the negative control test
# below), so there is no dependable window to target. We instead inject the
# fault directly.
#
# The injected layer is a synthetic ORPHAN (no parent, no names) rather than
# one of the pulled image's real layers, matching what a real interrupted
# pull actually leaves behind — an image record is only committed once every
# layer in its chain is complete, so a genuinely incomplete layer never has
# an image depending on it.
@test "CRI-O removes an incomplete-flagged layer on startup" {
	setup_crio
	start_crio_no_setup

	# Establish a real, fully-committed image so we can assert afterward that
	# it is completely unaffected by the unrelated orphan layer's cleanup.
	crictl pull "$SYNCFS_IMAGE"
	local image_id
	image_id=$(crictl images -q "$SYNCFS_IMAGE")
	[ -n "$image_id" ]

	# Stop CRI-O cleanly so layers.json is fully flushed and consistent before
	# we inject the fault.
	stop_crio_no_clean ""

	local layers_json
	layers_json=$(find "$TESTDIR/crio" -maxdepth 2 -name 'layers.json' 2>/dev/null | head -1)
	[ -n "$layers_json" ]

	# Append a synthetic orphan layer flagged incomplete. It has no "parent"
	# and no "names", so nothing (no image, no other layer) references it —
	# deleting it on startup cannot affect the real image pulled above.
	local fake_id="deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
	jq --arg id "$fake_id" \
		'. + [{"id": $id, "flags": {"incomplete": true}}]' \
		"$layers_json" >"$layers_json.tmp"
	mv "$layers_json.tmp" "$layers_json"

	# Restart CRI-O. containers/storage load() must detect the incomplete-
	# flagged orphan layer and discard it automatically on this startup.
	start_crio_no_setup

	# Confirm cleanup was logged for exactly the injected orphan layer.
	# (Avoid matching literal quote characters around the ID: logrus's text
	# formatter escapes them as \" and exact rendering is formatter-version
	# dependent, so match the substring loosely instead.)
	run grep -c "Found incomplete layer.*$fake_id" "$CRIO_LOG"
	[ "$status" -eq 0 ]
	[ "$output" -gt 0 ]

	# The real image pulled above must be completely unaffected.
	run crictl images -q "$SYNCFS_IMAGE"
	[ "$status" -eq 0 ]
	[ "$output" = "$image_id" ]
}

# Pull-time overhead measurement  ─────────────────────
#
# Informational only, gated behind SYNCFS_BENCHMARK=1: on this VM's storage,
# run-to-run noise (hundreds of ms) is larger than the signal this is trying
# to measure, so it is not run as part of the normal suite.
@test "pull-time overhead of overlay.sync=filesystem is within acceptable range (informational)" {
	if [ "${SYNCFS_BENCHMARK:-}" != "1" ]; then
		skip "informational only; set SYNCFS_BENCHMARK=1 to run"
	fi

	local -i runs=3
	local -a times_with=()
	local -a times_without=()

	# --- Timed pulls WITH sync=filesystem ---
	setup_crio
	start_crio_no_setup

	local i start end
	for ((i = 0; i < runs; i++)); do
		crictl rmi "$SYNCFS_IMAGE" 2>/dev/null || true
		start=$(date +%s%3N)
		crictl pull "$SYNCFS_IMAGE"
		end=$(date +%s%3N)
		times_with+=($((end - start)))
	done

	# --- Timed pulls WITHOUT sync=filesystem ---
	# Reconfigure with sync disabled for a back-to-back comparison on the
	# same node under equivalent conditions.
	stop_crio_no_clean ""
	STORAGE_OPTIONS="" setup_crio
	start_crio_no_setup

	for ((i = 0; i < runs; i++)); do
		crictl rmi "$SYNCFS_IMAGE" 2>/dev/null || true
		start=$(date +%s%3N)
		crictl pull "$SYNCFS_IMAGE"
		end=$(date +%s%3N)
		times_without+=($((end - start)))
	done

	# Compute averages and emit results to the BATS tap stream (>&3).
	local sum_with=0 sum_without=0
	for t in "${times_with[@]}"; do ((sum_with += t)); done
	for t in "${times_without[@]}"; do ((sum_without += t)); done
	local avg_with=$((sum_with / runs))
	local avg_without=$((sum_without / runs))
	local delta=$((avg_with - avg_without))

	echo "#  performance results — informational, no hard threshold:" >&3
	echo "#   sync=filesystem: avg ${avg_with}ms over ${runs} runs (${times_with[*]})" >&3
	echo "#   sync=none:       avg ${avg_without}ms over ${runs} runs (${times_without[*]})" >&3
	echo "#   delta:           ${delta}ms" >&3
}

# ──  Negative control — recovery without sync=filesystem ────────────────
#
# Checks a narrower claim than the tests above: with the feature off, CRI-O's
# existing unclean-shutdown repair path still works and doesn't wipe unrelated
# images. Not evidence for sync=filesystem itself (the syncfs-call pair above
# covers that) — a SIGKILL can't show that either way, since the page cache
# survives a killed process and is flushed to disk regardless. The real
# durability proof, a genuine kernel panic, lives in the origin e2e suite.
@test "CRI-O still recovers from a hard kill without sync=filesystem (negative control)" {
	# Explicitly disable sync=filesystem for this negative-control test.
	#
	# clean_shutdown_file defaults to an absolute host path
	# (/var/lib/crio/clean.shutdown), not one scoped under $TESTDIR, so every
	# test's CRI-O instance in this file shares the same file. Under bats'
	# parallel jobs that makes the unclean-shutdown detection below race
	# against whichever other test's CRI-O last touched it. Scope it into
	# $TESTDIR via OVERRIDE_OPTIONS so this test is self-contained.
	OVERRIDE_OPTIONS="--clean-shutdown-file=$TESTDIR/clean.shutdown" STORAGE_OPTIONS="" setup_crio
	start_crio_no_setup

	# Force a real, in-flight pull. The image is preloaded by setup_crio;
	# without removing it first, "crictl pull" returns almost instantly and
	# the kill below would land well after the pull already finished.
	crictl rmi "$SYNCFS_IMAGE" 2>/dev/null || true

	# Baseline taken *after* the rmi: these are the images that must come
	# back unharmed. The image being (re-)pulled below is expected to be
	# absent in both "before" and "after" — the pull gets killed mid-flight
	# and must not leave a partially-committed image behind.
	local before
	before=$(crictl images -q | sort)

	crictl pull "$SYNCFS_IMAGE" &
	local pull_pid=$!
	sleep 3

	kill -9 "$CRIO_PID" 2>/dev/null || true
	wait "$CRIO_PID" 2>/dev/null || true
	unset CRIO_PID
	kill "$pull_pid" 2>/dev/null || true
	wait "$pull_pid" 2>/dev/null || true

	# Must start cleanly even without the syncfs durability guarantee, via
	# the unclean-shutdown repair path — and must not have silently wiped
	# anything that existed before the kill.
	start_crio_no_setup

	run grep -q "because of unclean shutdown" "$CRIO_LOG"
	[ "$status" -eq 0 ]

	# Whether the killed pull above finished before or after the kill landed
	# is a race (image size and runner speed both vary), so the re-pulled
	# image may or may not be present afterward — that's fine either way.
	# What must hold is that nothing that existed *before* the kill was lost.
	local after
	after=$(crictl images -q)
	local id
	for id in $before; do
		grep -qx "$id" <<<"$after"
	done
}
