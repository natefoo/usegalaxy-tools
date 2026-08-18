# Self-hosted GitHub Actions runner

Tool installation needs to mount CVMFS and stack a `fuse-overlayfs` on top of it, which
GitHub-hosted runners do not permit. `.github/workflows/test-install.yml` and
`.github/workflows/deploy.yml` therefore run on a self-hosted runner labeled `cvmfs`.

This document covers provisioning that runner and the repository settings it depends on.

## Host requirements

| Requirement | Notes |
|---|---|
| CVMFS client | With `/etc/cvmfs/keys/galaxyproject.org` populated. `.ci/cvmfs-fuse.conf` points `CVMFS_KEYS_DIR` at it. |
| `fuse-overlayfs` | The overlay is mounted in userspace, not with the kernel overlayfs driver. |
| `user_allow_other` in `/etc/fuse.conf` | Both mounts pass `allow_root`, which requires this. |
| Docker | Galaxy runs in a container; the runner user must be in the `docker` group. |
| `python3` with `venv` | `setup_ephemeris` builds a virtualenv per run. |
| `git`, `rsync`, `curl`, `tree`, `psmisc` | `rsync` copies the overlay upper dir to the Stratum 0; `tree` and `fuser` (from `psmisc`) are used when reporting and unmounting. |

Run the runner as a **dedicated non-root user**. It must be able to create files inside the
overlay from within the Galaxy container — see the `FIXME: unprivileged would be preferable` note
in `.ci/github-actions.sh`, which is why `fuse-overlayfs` is mounted with `allow_root`.

## Paths

Two directories, both owned by the runner user, both configurable via the runner service
environment (defaults shown):

```
SCRATCH_ROOT=/data/actions-runner/scratch        # per-run overlayfs and CVMFS mounts
CVMFS_CACHE_ROOT=/data/actions-runner/cvmfs-cache  # persistent CVMFS cache, kept warm between runs
```

`SCRATCH_ROOT` needs room for a full copy-up of whatever a single run installs. It must **not** be
set to `$GITHUB_WORKSPACE`: that is the git checkout, and creating the overlay directories inside
it would pollute the working tree that change detection diffs.

`CVMFS_CACHE_ROOT` is bounded by the `CVMFS_QUOTA_LIMIT` soft limit in `.ci/cvmfs-fuse.conf`,
currently 8 GB. To reclaim space sooner, check that no job is running and delete the
per-repository subdirectories under it, or the whole directory — the next run recreates what it
needs. A cold cache costs one slow run, nothing worse.

## SSH access to the Stratum 0

The deploy job opens an SSH control connection to the Stratum 0 to run `cvmfs_server transaction`
and `cvmfs_server publish`, and to `rsync` the overlay upper dir across.

- **Host keys need no setup.** The control connection is opened with
  `StrictHostKeyChecking=accept-new`, so the Stratum 0 key is recorded in the runner user's
  `~/.ssh/known_hosts` on first connect and verified on every deploy after that. If a Stratum 0 is
  ever rebuilt, deploys to it will fail until the stale entry is removed with `ssh-keygen -R`,
  which is the intended behaviour — a changed host key should stop a publish, not be accepted
  silently.
- **The private key is not stored on the runner.** It lives in the `cvmfs-publish` environment as
  the `STRATUM0_SSH_KEY` secret and is loaded into an `ssh-agent` for the life of the deploy job
  only. This is the point of using an environment: another workflow scheduled onto the same runner
  cannot reach the key. The agent is killed in an `if: always()` step, which matters on a
  persistent runner — a leaked agent would be a leaked key for every job that follows.

## Runner registration

Register the runner **to this repository**, not to the organization, with labels:

```
self-hosted, Linux, X64, cvmfs
```

Install the job-started hook, which cleans up mounts and scratch directories left behind when a
job is cancelled or times out (the runner SIGKILLs the job, so the script's trap handler never
runs):

```
ACTIONS_RUNNER_HOOK_JOB_STARTED=/path/to/usegalaxy-tools/.ci/runner-job-started.sh
```

Set it in the runner's `.env` file. If `SCRATCH_ROOT` is not the default, export it there too so
the hook cleans the right directory.

## Repository settings

- **Settings → Actions → General**
  - Fork pull request workflows: *Require approval for all external contributors*. This is what
    keeps a public repo's PRs from running arbitrary code on a privileged runner.
  - Workflow permissions: read-only by default.
- **Settings → Environments → `cvmfs-publish`**
  - Secret `STRATUM0_SSH_KEY` — the private key authorized on the Stratum 0 hosts.
  - No required reviewers: merge permission is already the gate, and a second approval click after
    merge would only re-confirm a decision the same people just made.
- **Settings → Branches → branch protection for `master`**
  - Require the `test-install` check to pass before merging. This replaces the convention of
    "merge only once you've verified the console output" with something actually enforced.
  - **Disable rebase merging.** The deploy workflow derives the PR's changes from
    `<merge_commit_sha>^1...<merge_commit_sha>`, which is correct for merge commits and squashes
    but not for rebase merges, where it would see only the PR's last commit.

### A caveat worth stating plainly

A repository-scoped runner can be targeted by *any* workflow in the repository — the "allow
selected workflows" control is a runner **group** feature, and runner groups are only available to
organizations and enterprises. The real protections here are the fork-approval setting above and
branch protection on `.github/workflows/`, plus keeping the Stratum 0 key in an environment rather
than on the runner's disk. Since only members of `@galaxyproject/tool-installers` and org admins
can approve fork PR runs or merge, this is adequate — but it is a policy control, not a technical
one, so it should be understood rather than assumed.

## Verifying the runner

Before pointing the real workflows at it, confirm the mount stack works under the runner user with
a throwaway workflow that does nothing but mount and unmount:

```yaml
jobs:
  smoke:
    runs-on: [self-hosted, cvmfs]
    steps:
      - uses: actions/checkout@v4
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
