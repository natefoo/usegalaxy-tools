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

DOCKER_RUN_LABEL='org.galaxyproject.usegalaxy-tools.runner-managed=true'

log() {
    echo "[runner-job-started] $*"
}

# Detached containers survive if the job is forcibly terminated. Remove them before unmounting their bind mounts.
if command -v docker >/dev/null 2>&1; then
    while read -r container_id; do
        [ -n "$container_id" ] || continue
        log "Removing stale container: ${container_id}"
        docker rm -f "$container_id" || log "WARNING: could not remove container ${container_id}"
    done < <(docker ps -aq --filter "label=${DOCKER_RUN_LABEL}" 2>/dev/null)
fi

[ -d "$SCRATCH_ROOT" ] || {
    log "${SCRATCH_ROOT} does not exist, no scratch state to clean"
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

# Remove run dirs that no longer contain a mount. Completed-job logs have already been uploaded, and canceled jobs must
# not leave an overlay upper/work directory that a re-run could reuse.
for run_dir in "$SCRATCH_ROOT"/*; do
    [ -d "$run_dir" ] || continue
    if findmnt -rno TARGET | grep -q "^${run_dir}\(/\|$\)"; then
        log "Leaving ${run_dir}, still has a mount under it"
        continue
    fi
    log "Removing stale run dir: ${run_dir}"
    rm -rf "$run_dir" || log "WARNING: could not remove ${run_dir}"
done

exit 0
