# T3 Code stable release watch

Dagu checks the upstream GitHub releases Atom feed every 15 minutes for plain
`vX.Y.Z` release tags. It follows GitHub's public `releases/latest` redirect to
find the current stable release, even when nightly and mobile builds fill the
feed. It calls GitHub's API if the redirect yields no stable tag or if the feed
has a higher stable version that needs publication confirmed. The watcher only
considers versions newer than v0.1.11, the target pinned in the local client
`main/` checkout, and the last launch it recorded.

When it finds a new release, the watcher starts an update and release thread in
the `t3code-client` project. The thread inherits the Git operator registration
from the setup thread and follows the client's documented review,
merge, and publication process. It creates a checkout in the project's
`worktrees/` folder from the client repository's bare clone.

The watcher keeps `config.json` and `last-launch.json` together in
`~/.local/share/dagu/t3code-stable-release-watch/` on the workspace's persistent Dagu mount.
If T3 accepted a launch before Dagu could save it, the next run looks up the
release thread by title and starts a run there if needed. If work in a release
thread fails after its run starts, resume that thread. Check Dagu run history
for polling or dispatch errors. The next scheduled run retries the check.

In `config.json`, set `project_root` to the absolute T3 project path, `operator`
to the assigned Git operator handle, and `operator_source` to a thread registered
to that operator.

Run the check on demand from the Dagu UI or with:

```sh
dagu start --config /etc/dagu/config.yml /workflows/local/dags/t3code-stable-release-watch.yml
```
