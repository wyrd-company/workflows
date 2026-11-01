<main-worfklows-context path="/workflows/main">
This folder is the `main` checkout of the `workflows` repository.

Its purpose is to provide sub-dags, scripts, and skills for re-usable workflows/patterns.

To suggest/request changes, create a worktree branch from `origin/main` and submit a GitHub PR. Perform the standard review cycle, and then once it is ready ask the user to merge the changes into `main` so all workspaces can benefit from shared improvements/patterns.

```tree
.
../local/             # Local dags, scripts, tests, etc
../worktrees/main/    # Worktree for suggesting changes to `main`. Use semantic branch/worktree names.
├── bin/              # Re-usable scripts called by dags, on the Dagu PATH
├── sub-dags/         # Re-usable sub-dags
├── skills/           # Skills related to re-usable sub-dags/patterns here.
│   ├── references/   # Additional documentation for the skill for progressive discovery.
│   ├── scripts/      # Scripts to make the skill or template easier to use. As appropriate
│   ├── template/     # Toha template for the skill. As appropriate.
│   ├── SKILL.md      # The SKILL.md file
│   └── template.yml  # The Toha template config. As appropriate
├── template/         # Toha template to initilialize new workspace branches
└── tests/            # Tests here. Namespace them with the sub-dag e.g. `<sub-dag-file-name>/<test>.py|sh`
```
</main-workflows-context>