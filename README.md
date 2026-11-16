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

Trowel passes the push's `REF` and `SHA` as params. Pushes carry no branch in
their NATS subject, so each DAG's step skips any `REF` but `refs/heads/main`:
the run succeeds with the step skipped. Both DAGs share the `workspace-update`
queue, so they never run at once.

`workspace-update-dotfiles` fails rather than update when the chezmoi source
is not a clean checkout of `main`, so a branch there is never rebased.

Run one by hand from the Dagu UI, or:

```sh
dagu enqueue --config /etc/dagu/config.yml /workflows/main/sub-dags/workspace-update-dotfiles.yml
```

Test: `tests/workspace-update/preconditions.sh` dry-runs both DAGs and checks
which refs run the step.
