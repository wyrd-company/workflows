# Wryd Company Dagu Workflows

This is the `main` branch of the `workflows` repo. It contains:

- re-useable sub-dags
- re-useable scripts
- a [toha]() template for initializing new workspace branches
- sub-dag tests
## Workspace updates

Every workspace keeps itself current with its shared repositories. Its Trowel
(configured by workspace-ansible's `templates/etc/trowel/config.yml.j2`) takes
each push GitHub reports for them and enqueues a DAG in `sub-dags/`:

| Push to | DAG | Runs |
| --- | --- | --- |
| `workspace-ansible` | `workspace-update-ansible` | `sudo ansible-sync`: pulls the playbook and reapplies it |
| `workspace-dotfiles`, `skills` | `workspace-update-dotfiles` | `chezmoi update --init`: pulls the dotfiles and applies them; every apply fast-forwards the skills clone |
| `workflows` | `workspace-update-workflows` | `git pull --ff-only` in `/workflows/main` |

Trowel passes the push's `REF` and `SHA` as params. Pushes carry no branch in
their NATS subject, so each DAG's step skips any `REF` but `refs/heads/main`:
the run succeeds with the step skipped. The DAGs share the `workspace-update`
queue, so they never run at once.

`workspace-update-dotfiles` and `workspace-update-workflows` fail rather than
update when their checkout is not a clean `main`, so local work is never
rebased or merged.

Run one by hand from the Dagu UI, or:

```sh
dagu enqueue --config /etc/dagu/config.yml /workflows/main/sub-dags/workspace-update-dotfiles.yml
```

Test: `tests/workspace-update/preconditions.sh` dry-runs the DAGs and checks
which refs run the step.

## Fork sync

A workspace may run on forks of the workspace repositories (`upstream_org` set
in `/etc/workspace/config.yml`). Its Trowel then also takes each push to an
upstream repository and enqueues `sub-dags/fork-sync.yml` with `UPSTREAM` and
`FORK` (`owner/repo`), `REF` and `SHA`. The step skips any `REF` but
`refs/heads/main`, as the workspace-update DAGs do, and runs `fork-sync-run`:

1. **Compare** upstream's `main` with the fork's through the GitHub API. When
   the fork is not behind, the run succeeds with nothing to do.
2. **No commits of its own:** `POST repos/{FORK}/merge-upstream` with
   `branch=main` fast-forwards the fork on the server: no clone, no force-push.
3. **Commits of its own:** `fork-sync-rebase` fetches both into a cached clone,
   rebases the fork's commits onto upstream's `main` and, once that succeeds,
   pushes a backup tag
   `fork-sync/backup-<UTC timestamp>` of the fork's old head, then pushes with
   `--force-with-lease=main:<old head>`.
4. **Conflict:** the rebase is aborted and nothing is pushed. `fork-sync-alert`
   opens an issue on the fork labelled `fork-sync`, titled
   `fork-sync: main conflicts with <UPSTREAM>`, or comments on the open one. It
   gives the upstream SHA, the fork commits being replayed and the conflicting
   files. It notifies `https://ntfy.sh/$NTFY_TOPIC` with a link to the issue,
   and the run fails. Each alert records the upstream and fork SHAs in the
   issue; while they match the current ones, later runs fail without alerting
   again. The next sync that succeeds closes the issue (`fork-sync-resolve`).

The fork's push then triggers the fork's own `workspace-update-*` DAG, which
applies it like any other push.

**Rebase, not merge.** The fork carries a small patch stack on top of upstream.
Rebasing keeps that stack linear and on top, where it is easy to read
(`git log upstream/main..main`) and easy to send upstream as pull requests; a
patch upstream takes drops out of the stack on its own. Merging would bury the
fork's commits under a merge per upstream push. The cost is a force-push, which
two things make recoverable: the backup tag holds every head a sync replaced,
and the lease means a sync only replaces the head it rebased. A lease failure
means someone pushed to the fork meanwhile: the run fails with exit status 3,
overwrites nothing, and a rerun or the next upstream push retries.

The rebase linearises the fork's own non-merge commits, so merge commits in the
fork's history, such as those from GitHub's "Sync fork" button, are dropped.
That is intended. To restore a replaced head, fetch its tag and push it back:
`git fetch origin tag fork-sync/backup-<timestamp>`, then
`git push --force-with-lease=main origin fork-sync/backup-<timestamp>:refs/heads/main`.

**Cache.** The clone is a bare repository at `/repos/fork-sync/<owner>/<repo>.git`,
beside the workspace's other bare clones in `/repos`, which is bind-mounted from
the workspace folder and survives restarts. Each run checks out a throwaway
worktree from it and removes it on exit. Delete the cache freely: the next
rebase clones it again. `fork-sync-rebase` also takes `<repo>.git.lock` with
`flock`.

**Queue.** The DAG has its own `fork-sync` queue, which no config defines, so
runs execute one at a time and never overlap for a fork. It is not the
`workspace-update` queue: the sync's push enqueues the fork's own
`workspace-update-*` DAG, which then neither waits behind nor blocks the next
sync.

**Permissions.** `wyrd-automation[bot]` needs contents:write on the fork, for
merge-upstream and the pushes, and issues:write for the conflict issue. GitHub
disables issues on a new fork: enable them in the fork's settings. Without
them, the notification carries the conflict details, and reruns notify again.
An upstream change under `.github/workflows/` also needs the App's workflows
permission to push.

Run one by hand from the Dagu UI, or:

```sh
dagu enqueue --config /etc/dagu/config.yml /workflows/main/sub-dags/fork-sync.yml -- \
    UPSTREAM=wyrd-company/workflows FORK=boblangley/workflows
```

Test: `tests/fork-sync/sync.sh` dry-runs the DAG for the precondition, then runs
`fork-sync-run` against local bare repositories standing in for upstream and the
fork, with `gh` and `ntfy` stubbed on PATH. It covers the skip, not behind, the
fast-forward, the rebase, dropped merge commits, a conflict, duplicate-alert
suppression, issues disabled and a lease failure.
