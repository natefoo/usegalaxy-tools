#!/usr/bin/env bash
# Runner job-started hook: clean up mounts and scratch dirs left behind by previous jobs.
#
# A cancelled or timed-out Actions job is SIGKILLed, so the trap handler in .ci/github-actions.sh never runs and its
# CVMFS/fuse-overlayfs mounts survive into the next job, which then fails in mount_overlay. This also reaps run dirs
# left behind by the lazy-unmount fallback in unmount_cvmfs_lower, once the kernel has released them.
#
# Install on the runner by pointing ACTIONS_RUNNER_HOOK_JOB_STARTED at a copy of this script; see
# docs/self-hosted-runner.md. It is deliberately a hook rather than a workflow step so that it also protects runs of
# workflows that know nothing about it.

set -uo pipefail

: ${SCRATCH_ROOT:=/data/actions-runner/scratch}

# Run dirs older than this are removed even if idle, in case a run dir was orphaned without a mount
MAX_AGE_DAYS=1

log() {
    echo "[runner-job-started] $*"
}

[ -d "$SCRATCH_ROOT" ] || {
    log "${SCRATCH_ROOT} does not exist, nothing to clean"
    exit 0
}

# Unmount deepest-first so the overlayfs mount goes before the CVMFS lower mount it is stacked on
while read -r mountpoint; do
    case "$mountpoint" in
        "${SCRATCH_ROOT}"/*) ;;
        *) continue ;;
    esac
    log "Unmounting stale mount: ${mountpoint}"
    fusermount -u "$mountpoint" \
        || fusermount -u -z "$mountpoint" \
        || log "WARNING: could not unmount ${mountpoint}"
done < <(findmnt -rno TARGET | grep "^${SCRATCH_ROOT}/" | sort -r)

# Remove run dirs that no longer contain a mount. Anything still mounted is left alone: a subsequent job gets a fresh
# $GITHUB_RUN_ID and so its own run dir, and the mount should be reapable on a later pass.
for run_dir in "$SCRATCH_ROOT"/*; do
    [ -d "$run_dir" ] || continue
    if findmnt -rno TARGET | grep -q "^${run_dir}\(/\|$\)"; then
        log "Leaving ${run_dir}, still has a mount under it"
        continue
    fi
    if [ -n "$(find "$run_dir" -maxdepth 0 -mtime "+${MAX_AGE_DAYS}")" ]; then
        log "Removing stale run dir: ${run_dir}"
        rm -rf "$run_dir" || log "WARNING: could not remove ${run_dir}"
    fi
done

exit 0
