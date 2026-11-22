# T3 Code stable release watch

Dagu checks the upstream GitHub releases Atom feed every 15 minutes for plain
`vX.Y.Z` release tags. When the feed has no newer stable tag, it checks GitHub's
latest-release endpoint because nightly and mobile builds can fill the feed.
The watcher uses the newest eligible version. Its starting point is v0.1.11,
which already had an update underway, or the client's target if that is newer.

When it finds a new release, the watcher starts an update and release thread in
the `t3code-client` project. The thread inherits the Git operator registration
from the setup thread and follows the client's documented review,
merge, and publication process. It creates a checkout in the project's
`worktrees/` folder from the client repository's bare clone.

The most recent launch is recorded in
`${XDG_STATE_HOME:-$HOME/.local/state}/dagu/t3code-stable-release-watch/last-launch.json`.
If T3 accepted a launch before Dagu could save it, the next run looks up the
release thread by title. If work in a release thread fails, resume that thread.

The watcher reads this workspace's setup from
`${XDG_CONFIG_HOME:-$HOME/.config}/dagu/t3code-stable-release-watch.json`.
Set `project_root` to the absolute T3 project path, `operator` to the assigned
Git operator handle, and `operator_source` to a thread registered to that operator.

Run the check on demand from the Dagu UI or with:

```sh
dagu start --config /etc/dagu/config.yml t3code-stable-release-watch
```
