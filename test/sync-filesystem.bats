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
# discards them, leaving the store clean without any escalated repair.
#
# Test coverage:
#   - UC-09: A successfully committed image must survive a CRI-O restart.
#   - UC-08: An incomplete layer left by a hard kill must be removed on restart.
#   - UC-12: Pull-time overhead of sync=filesystem is measured and logged
#            (informational — no hard pass/fail threshold).
#   - UC-10: Negative control — without sync=filesystem CRI-O must still recover
#            from a hard kill (repair always works; this documents the comparison).
#
# Crash-consistency with genuine lost writes (kernel power-loss) cannot be
# tested here without device-mapper fault injection; those scenarios are
# covered by the manual test plan in OCPNODE-4720.

load helpers

# Large multi-layer image — same as the manual test plan — so UC-12 timing
# results are directly comparable to the recorded baseline (7.55 s / 6.64 s).
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

# ── UC-09: Image persistence across restart ───────────────────────────────────
#
# With sync=filesystem, the final metadata commit (clearing incompleteFlag) is
# preceded by syncfs().  A clean restart must find the layer intact, load it
# from the same on-disk state, and report the same image ID.
@test "images pulled with sync=filesystem survive a CRI-O restart" {
	setup_crio
	start_crio_no_setup

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

# ── UC-08: Incomplete-layer cleanup after hard kill ───────────────────────────
#
# SIGKILL mid-pull is the closest in-process equivalent to a kernel crash for
# testing the incompleteFlag path: the flag is persisted *before* any data is
# written, so it survives a kill at any point during extraction.  On the next
# startup, containers/storage load() must detect and discard the incomplete
# entry, logging "Found incomplete layer".
@test "CRI-O removes an incomplete layer left by a hard kill mid-pull" {
	setup_crio
	start_crio_no_setup

	# Begin pulling in the background so a layer is in-flight and the
	# incompleteFlag has been committed to layers.json.
	crictl pull "$SYNCFS_IMAGE" &
	local pull_pid=$!

	# Wait long enough for at least one layer to start extracting.
	# The flag is written before data, so even a brief wait is sufficient.
	sleep 3

	# SIGKILL CRI-O — leaves the incomplete layer entry in layers.json.
	stop_crio_no_clean -9
	kill "$pull_pid" 2>/dev/null || true

	# Restart from the partially-written storage directory.
	# CRI-O must detect and discard the incomplete layer on startup,
	# then reach a functional ready state without manual intervention.
	start_crio_no_setup

	# Confirm cleanup was logged.
	run grep -c "Found incomplete layer" "$CRIO_LOG"
	[ "$status" -eq 0 ]
	[ "$output" -gt 0 ]

	# CRI-O must be operational after the cleanup.
	run crictl images
	[ "$status" -eq 0 ]
}

# ── UC-12: Pull-time overhead measurement (informational) ─────────────────────
#
# Pass criteria from the test plan: "Overhead is documented as a factual data
# point.  There is no hard pass/fail threshold unless one is agreed with the
# team."  This test always passes; results appear in the CI log.
@test "pull-time overhead of overlay.sync=filesystem is within acceptable range (informational)" {
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

	echo "# UC-12 performance results — informational, no hard threshold:" >&3
	echo "#   sync=filesystem: avg ${avg_with}ms over ${runs} runs (${times_with[*]})" >&3
	echo "#   sync=none:       avg ${avg_without}ms over ${runs} runs (${times_without[*]})" >&3
	echo "#   delta:           ${delta}ms" >&3
	echo "#   Baseline from manual test: +0.91 s (+13.7%) on GCP with 409 MB image." >&3
}

# ── UC-10: Negative control — recovery without sync=filesystem ────────────────
#
# Without sync=filesystem, the same SIGKILL scenario must still not leave the
# store permanently broken: the incompleteFlag mechanism operates regardless of
# sync mode, so incomplete layers are always cleaned up on restart.
# The distinction from UC-08 is that without syncfs(), layer *content* on disk
# may be inconsistent at the block level after a real power-loss event — but
# that cannot be demonstrated without kernel-level fault injection (dm-flakey).
@test "CRI-O still recovers from a hard kill without sync=filesystem (negative control)" {
	# Explicitly disable sync=filesystem for this negative-control test.
	STORAGE_OPTIONS="" setup_crio
	start_crio_no_setup

	crictl pull "$SYNCFS_IMAGE" &
	local pull_pid=$!
	sleep 3

	stop_crio_no_clean -9
	kill "$pull_pid" 2>/dev/null || true

	# Must start cleanly even without the syncfs durability guarantee.
	start_crio_no_setup

	run crictl images
	[ "$status" -eq 0 ]
}
