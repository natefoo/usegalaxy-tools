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
| `mdata-get`, `mdata-put`, `mdata-delete` | How the guest receives its runner registration at boot. Present in `/usr/sbin` in the SmartOS-provided Linux images but owned by no package, so a rebuild from a stock image loses them — and a runner with no way to read its registration simply never comes online. |

Run each runner as a **dedicated non-root user**. It must be able to create files inside the
overlay from within the Galaxy container — see the `FIXME: unprivileged would be preferable` note
in `.ci/github-actions.sh`, which is why `fuse-overlayfs` is mounted with `allow_root`.

That user is tidiness, **not a security boundary**. Membership in the `docker` group is root-equivalent, so a job can
reach root on its host whenever it wants to. The boundary is the snapshot rollback below, and the separation of the
test and publish hosts. Do not put anything on a runner host on the assumption that the runner user cannot read it.

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
  only.

## Runner registration

Create two **organization-level runner groups**, each visible only to `galaxyproject/usegalaxy-tools`, each with
*Allow public repositories* and *Restrict to selected workflows* on, and each allowing exactly one workflow:

| group | allowed workflow |
|---|---|
| `cvmfs-test` | `galaxyproject/usegalaxy-tools/.github/workflows/test-install.yml` |
| `cvmfs-publish` | `galaxyproject/usegalaxy-tools/.github/workflows/deploy.yml@refs/heads/main` |

Each group is served by its own host, and no host is ever in both. A just-in-time registration carries exactly the
labels the hypervisor asks for, and none of the `self-hosted`/`Linux`/`X64` defaults that `config.sh` would add, so
`cvmfs` is the only label to select on. The test host executes PR-controlled code, so give it no secrets or SSH/write
access to Stratum 0; allow only the read-only HTTP access needed by the CVMFS client. Keep exactly one runner in the
publish group so its runner queue serializes every deploy without dropping pending runs. The publish host must never
accept a `pull_request` job.

### Runner lifecycle

Neither runner is registered persistently. Each host is a bhyve VM that runs **exactly one job per boot** and then
powers itself off, and the hypervisor rolls its disk back to a clean snapshot before booting it again. Provisioning of
both the guest and hypervisor halves lives in the [Ansible playbook][infrastructure-playbook], not in this repository.

One cycle:

1. The hypervisor sees the VM stopped and rolls its disk dataset back to the clean snapshot.
2. It calls `POST /orgs/galaxyproject/actions/runners/generate-jitconfig` with the group id and the `cvmfs` label, and
   writes the returned config into the VM's `customer_metadata` as `jitconfig`.
3. It starts the VM. The boot unit reads the config with `mdata-get`, removes it with `mdata-delete`, and execs
   `run.sh --jitconfig`.
4. The runner takes one job, reports its result, deregisters itself, and exits.
5. The guest powers off.

Because the registration is generated on the hypervisor, neither VM holds a credential that can register a runner: a
compromised test host cannot add itself to the publish group (and it is regardless single-use and consumed before any
job code runs).

If a rollback fails, the hypervisor leaves the VM stopped rather than starting it dirty, and repeated failed boots
trip a backoff. Watch for that state: a group with no runner in it does not fail jobs, it queues them silently until
GitHub cancels them **24 hours** later.

### Hypervisor credential

Minting a registration is the one privileged thing the hypervisor does, and it needs a token for it. That token is a
**fine-grained personal access token**, currently owned by **@natefoo** — a personal credential doing an
infrastructure job, which is worth knowing before it becomes a surprise.

| | |
|---|---|
| Location | `/opt/custom/etc/gha-runner-cycle.token` on the hypervisor, `root:root`, mode `0600` |
| Read by | `gha-runner-cycle.sh`, via the Ansible-managed conf beside it |
| Resource owner | the `galaxyproject` organization |
| Permission | **Organization permissions → Self-hosted runners → Read and write**, and nothing else |

**Keep it off GitHub.** It must never become a repository or environment secret. A workflow able to read it could
register a runner into the publish group, which is the boundary the split hosts exist to draw.

**It expires.** Renew it before it does, and record the expiry date somewhere that is watched, because this credential
fails in the quiet direction: once `generate-jitconfig` returns 401 the cycle script logs the failure and leaves the VM
stopped, the runner group empties, and jobs queue against nothing until GitHub cancels them 24 hours later. Nothing
turns red in the meantime. A job sitting in *Waiting for a runner* with an empty runner group is the symptom;
`gha-runner-cycle.sh`'s log on the hypervisor is where the cause is visible.

### Job-started hook

The hook lives in the [Ansible playbook][infrastructure-playbook], not here, and is installed into each golden image —
never run it from a repository checkout that a PR can modify:

```
ACTIONS_RUNNER_HOOK_JOB_STARTED=/data/actions-runner-hooks/usegalaxy-tools-job-started.sh
RUNNER_EPHEMERAL_HOST=true
```

Keep that directory root-owned and outside the runner user's home, so the hook is not something a job can edit on its
way past.

With `RUNNER_EPHEMERAL_HOST=true` the hook asserts the host is clean and fails the job if it is not. That is how a
broken rollback surfaces, instead of the host quietly reverting to being a persistent one that carries state between
PRs. Without the variable it removes leftover containers, mounts, and scratch directories instead, which is the right
behaviour on a host that is not cycled. If `SCRATCH_ROOT` is not the default, export it alongside these so the hook
checks the right directory. Run only one runner service per host and scratch root, because the hook assumes every
existing run directory is stale.

## Repository settings

- **Settings → Actions → General**
  - Fork pull request workflows: *Require approval for all external contributors*. Approval controls scheduling; it
    does not make PR code trusted, which is why the test runner is isolated from publishing.
  - Workflow permissions: read-only by default.
- **Settings → Environments → `cvmfs-publish`**
  - Secret `STRATUM0_SSH_KEY` — the private key authorized on the Stratum 0 hosts.
    The environment exists to scope that secret, **not** to add an approval step: merging is the authorization gate,
    and a second "Approve and deploy" click would only re-confirm a decision the same people made moments earlier.
    Leave required reviewers unset. Deployment branch policy must stay at *No restriction* — a `pull_request_target`
    run is `refs/pull/N/merge`, which no branch policy can match.
- **Settings → Branches → branch protection for the default branch**
  - Require the `test-install` check to pass before merging. The check always reports, including for PRs without tool
    changes; only its privileged installation dependency is conditional.
  - Require pull requests, with both **Require approvals** and **Require review from Code Owners**. The approval count
    is path-agnostic; only the code owner requirement makes the split in `.github/CODEOWNERS` binding, so that a change
    under `.ci/` or `.github/` needs `@galaxyproject/tool-installers-admins` rather than any tool installer. The deploy
    workflow runs merged code with the Stratum 0 agent already loaded, so this is what bounds who can change what it
    executes.
  - **Disable rebase merging.** The deploy workflow derives the PR's changes from
    `<merge_commit_sha>^1...<merge_commit_sha>`, which is correct for merge commits and squashes
    but not for rebase merges, where it would see only the PR's last commit.

[infrastructure-playbook]: https://github.com/galaxyproject/infrastructure-playbook/
