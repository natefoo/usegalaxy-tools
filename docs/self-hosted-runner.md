# Self-hosted GitHub Actions runner

Tool installation needs to mount CVMFS and stack a `fuse-overlayfs` on top of it, which
GitHub-hosted runners do not permit. `.github/workflows/test-install.yml` and
`.github/workflows/deploy.yml` therefore run on isolated self-hosted runners labeled `cvmfs`.

This document covers provisioning those runners and the repository settings they depend on. The PR-test and publish
jobs must never share a host: PR code is untrusted even after a workflow run is approved.

## Host requirements

| Requirement | Notes |
|---|---|
| CVMFS client | With `/etc/cvmfs/keys/galaxyproject.org` populated. `.ci/cvmfs-fuse.conf` points `CVMFS_KEYS_DIR` at it. |
| `fuse-overlayfs` | The overlay is mounted in userspace, not with the kernel overlayfs driver. |
| `user_allow_other` in `/etc/fuse.conf` | Both mounts pass `allow_root`, which requires this. |
| Docker | Galaxy runs in a container; the runner user must be in the `docker` group. |
| `python3` with `venv` | `setup_ephemeris` builds a virtualenv per run. |
| `git`, `rsync`, `curl`, `tree`, `psmisc` | `rsync` copies the overlay upper dir to the Stratum 0; `tree` and `fuser` (from `psmisc`) are used when reporting and unmounting. |

Run each runner as a **dedicated non-root user**. It must be able to create files inside the
overlay from within the Galaxy container — see the `FIXME: unprivileged would be preferable` note
in `.ci/github-actions.sh`, which is why `fuse-overlayfs` is mounted with `allow_root`.

## Paths

Two directories, both owned by the runner user, both configurable via the runner service
environment (defaults shown):

```
SCRATCH_ROOT=/data/actions-runner/scratch          # per-run overlayfs and CVMFS mounts
CVMFS_CACHE_ROOT=/data/actions-runner/cvmfs-cache  # CVMFS cache
```

`SCRATCH_ROOT` needs room for a full copy-up of whatever a single run installs. It must **not** be
set to `$GITHUB_WORKSPACE`: that is the git checkout, and creating the overlay directories inside
it would pollute the working tree that change detection diffs.

Both hosts are rolled back to a clean snapshot, so neither directory survives between runs and
every run starts with a cold cache. `CVMFS_QUOTA_LIMIT` in `.ci/cvmfs-fuse.conf` still bounds the
cache within a run, currently 8 GB.

## SSH access to the Stratum 0

The deploy job opens an SSH control connection to the Stratum 0 to run `cvmfs_server transaction`
and `cvmfs_server publish`, and to `rsync` the overlay upper dir across.

- **Provision host keys before the first deploy.** Install keys whose fingerprints were verified out of band in the
  publish runner user's `~/.ssh/known_hosts` or the system `ssh_known_hosts`. The control connection uses
  `StrictHostKeyChecking=yes`, so an absent or changed key stops the deploy.
- **The private key is not stored on the runner.** It lives in the `cvmfs-publish` environment as
  the `STRATUM0_SSH_KEY` secret and is loaded into an `ssh-agent` for the life of the deploy job
  only. The publish runner group only permits the default-branch deploy workflow, and required environment reviewers
  provide a separate authorization gate. The agent is killed in an `if: always()` step.

## Runner registration

Create two **organization-level runner groups** that allow only selected workflows:

- `cvmfs-test` allows only `galaxyproject/usegalaxy-tools/.github/workflows/test-install.yml`.
- `cvmfs-publish` allows only `galaxyproject/usegalaxy-tools/.github/workflows/deploy.yml` from the default branch.

Register separate hosts in the two groups with the labels `self-hosted, Linux, X64, cvmfs`. Do not place a host in
both groups. The test host executes PR-controlled code, so give it no secrets or SSH/write access to Stratum 0; allow
only the read-only HTTP access needed by the CVMFS client. Keep exactly one runner in the publish group so its runner
queue serializes every deploy without dropping pending runs. The publish host must never accept a `pull_request` job.

Both hosts are rolled back to a clean snapshot between runs. On the test host this is what prevents PR-controlled code
from persisting to a later run; on the publish host it is not load-bearing, but keeping the two identical means there
is one operational story rather than two.

Install the job-started hook on each host. It removes labeled Galaxy containers, mounts, and scratch directories left
behind when a job is forcibly terminated:

```
ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/actions-runner-hooks/usegalaxy-tools-job-started.sh
```

Copy the hook from `.ci/runner-job-started.sh` to that root- or configuration-management-owned path; do not execute a
hook from a repository checkout that a PR can modify. Set it in the runner's `.env` file. If `SCRATCH_ROOT` is not the
default, export it there too so the hook cleans the right directory. Run only one runner service per host and scratch
root, because a job-started hook assumes that every existing run directory is stale.

## Repository settings

- **Settings → Actions → General**
  - Fork pull request workflows: *Require approval for all external contributors*. Approval controls scheduling; it
    does not make PR code trusted, which is why the test runner is isolated from publishing.
  - Workflow permissions: read-only by default.
- **Settings → Environments → `cvmfs-publish`**
  - Secret `STRATUM0_SSH_KEY` — the private key authorized on the Stratum 0 hosts.
  - Add `@galaxyproject/tool-installers` as required reviewers and prevent self-review. This is the deploy authorization
    gate; ordinary merge permission is not sufficient.
- **Settings → Branches → branch protection for `master`**
  - Require the `test-install` check to pass before merging. The check always reports, including for PRs without tool
    changes; only its privileged installation dependency is conditional.
  - Require pull requests and CODEOWNER approval, including for `.github/workflows/` and `.ci/`, without administrator
    bypass.
  - **Disable rebase merging.** The deploy workflow derives the PR's changes from
    `<merge_commit_sha>^1...<merge_commit_sha>`, which is correct for merge commits and squashes
    but not for rebase merges, where it would see only the PR's last commit.

## Verifying the runner

Before pointing the real workflows at it, confirm the mount stack works under the runner user with
a throwaway workflow that does nothing but mount and unmount:

```yaml
jobs:
  smoke:
    runs-on:
      group: cvmfs-test
      labels: cvmfs
    steps:
      - uses: actions/checkout@v7
      - run: |
          set -euo pipefail
          export REPO_STRATUM0=cvmfs0-psu1.galaxyproject.org
          export CVMFS_CACHE=/data/actions-runner/cvmfs-cache
          export CVMFS_SOCKETS=/tmp/smoke/sockets
          export RUN_DIR=/tmp/smoke
          mkdir -p /tmp/smoke/{lower,upper,work,mount,sockets}
          cvmfs2 -o config=.ci/cvmfs-fuse.conf,allow_root test.galaxyproject.org /tmp/smoke/lower
          fuse-overlayfs -o lowerdir=/tmp/smoke/lower,upperdir=/tmp/smoke/upper,workdir=/tmp/smoke/work,allow_root /tmp/smoke/mount
          ls /tmp/smoke/mount
          fusermount -u /tmp/smoke/mount
          fusermount -u /tmp/smoke/lower
```

Then open a PR that installs a single small tool on `test.galaxyproject.org` and check that the
run summary shows the overlay upper contents and the `shed_tool_conf.xml` diff, and that the
Stratum 0 revision (from `http://<stratum0>/cvmfs/<repo>/.cvmfspublished`) is **unchanged** — the
test job must never publish.
