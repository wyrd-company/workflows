<local-workflows-context path="/workflows/local">
This folder is a checkout of the `workspace/tavern` branch of the `workflows` repository.

It stores the workflow dags, scripts, tests, and documentation (wiki) for workflows that run on the local workspace.

To suggest/request changes, create a worktree branch from `workspace/tavern` and submit a GitPR. Perform the standard review cycle, and then once approved merge the changes into `workspace/tavern` so it can be put into use.

If a dag, script, or pattern would be useful to other workspaces, it belongs in `main` instead: follow `../main/AGENTS.md` and submit a PR against `main`.

```tree
.
../main/            # Shared sub-dags, scripts, skills,etc
../worktrees/local/ # Worktree changes. Use semantic branch/worktree names.
├── bin/            # Scripts here, on the Dagu PATH. Prefix them with the dag e.g. `<dag-file-name>-<script>.py|sh`
├── dags/           # Keep local dags here
├── tests/          # Tests here. Namespace them with the dag e.g. `<dag-file-name>/<test>.py|sh`
└── wiki/           # Document local dags here. Make sure each dag has a wiki file e.g. `<dag-file-name>.md`
```
</local-workflows-context>