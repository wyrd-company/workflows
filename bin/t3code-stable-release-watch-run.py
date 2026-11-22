#!/usr/bin/python3

"""Start a local T3 thread when T3 Code publishes a new stable version."""

import fcntl
import json
import re
import subprocess
import sys
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from xml.etree import ElementTree

UPSTREAM = "https://github.com/pingdotgg/t3code"
RELEASES_API = "https://api.github.com/repos/pingdotgg/t3code/releases"
LATEST = f"{RELEASES_API}/latest"
INITIAL_BASELINE = "v0.1.11"  # This release already had its own update thread at setup.
ATOM = {"atom": "http://www.w3.org/2005/Atom"}
STABLE_TAG = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")


def stable_version(tag):
    match = STABLE_TAG.fullmatch(tag)
    return tuple(map(int, match.groups())) if match else None


def fetch(url):
    request = Request(url, headers={"User-Agent": "t3code-client-release-watch"})
    with urlopen(request, timeout=20) as response:
        return response.read()


def published_release(tag):
    try:
        release = json.loads(fetch(f"{RELEASES_API}/tags/{tag}"))
    except HTTPError as error:
        if error.code == 404:
            return False
        raise
    return release["tag_name"] == tag and not (release["draft"] or release["prerelease"])


def newest_release(floor):
    feed = ElementTree.fromstring(fetch(f"{UPSTREAM}/releases.atom"))
    if feed.tag != f"{{{ATOM['atom']}}}feed":
        raise ValueError("Expected the GitHub releases Atom feed")
    tags = [
        entry.findtext("atom:id", default="", namespaces=ATOM).split("/", 2)[-1]
        for entry in feed.findall("atom:entry", ATOM)
    ]
    candidates = [tag for tag in tags if (stable_version(tag) or ()) > floor]
    if candidates:
        tag = max(candidates, key=stable_version)
        if published_release(tag):
            return tag

    # Nightly and mobile builds can displace all recent stable tags from the feed.
    tag = json.loads(fetch(LATEST))["tag_name"]
    return tag if (stable_version(tag) or ()) > floor else None


def t3_json(*args, prompt=None):
    result = subprocess.run(
        ["/usr/local/bin/t3", "thread", *args, "--json"],
        input=prompt, text=True, stdout=subprocess.PIPE, check=True, timeout=25,
    )
    return json.loads(result.stdout)


def launch_prompt(tag, project_root, operator, operator_source):
    return f"""The local Dagu release watcher started this thread. Operator {operator} configured it in T3 thread {operator_source}.

Update and release wyrd-company/t3code-client for upstream T3 Code {tag}.
Upstream release: {UPSTREAM}/releases/tag/{tag}

Use `git operator set --from {operator_source}` to inherit the Git operator registration.
Work in the t3code-client repo under {project_root}. Read `main/AGENTS.md`,
`worktrees/AGENTS.md`, the `tracking-t-code` section of
`main/docs/technical-designs/releasing.yml`, and the `upstream-updates` section
of `main/docs/technical-designs/tool-scope.yml`.

Check for an existing update or release before starting duplicate work. Fetch
client origin/main and create a worktree from `t3code-client.git` under
`worktrees/`. Verify that `t3@{tag[1:]}` is available on npm before changing the pin.

Follow the repo's T3 Code update procedure, including contract and tool coverage,
fixtures, live checks, and release intents. Follow the client's documented merge
and release approval rules. Once those gates are satisfied, land the update,
run the documented Release and Publish process, and verify publication for the
affected units. Keep status, results, and any requests for the operator in this thread.
"""


def check(state_dir, project_root, operator, operator_source):
    state_dir.mkdir(parents=True, exist_ok=True)
    with (state_dir / "lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = state_dir / "last-launch.json"
        previous = json.loads(state.read_text())["tag"] if state.exists() else INITIAL_BASELINE
        manifest = Path(project_root) / "main/packages/t3code-lib/package.json"
        target = json.loads(manifest.read_text())["devDependencies"]["t3"]
        versions = [stable_version(tag) for tag in (previous, INITIAL_BASELINE, f"v{target}")]
        if None in versions:
            raise ValueError(f"Expected stable versions for the saved tag ({previous}) and client target ({target})")
        floor = max(versions)
        tag = newest_release(floor)
        if tag is None:
            print(f"No stable T3 Code release newer than v{'.'.join(map(str, floor))}.")
            return

        title = f"Update and release t3code-client for T3 Code {tag}"
        threads = t3_json("list", "--project", project_root)
        thread = next((thread for thread in threads if thread["title"] == title), None)
        action = "Found existing"
        if thread is None:
            launch = t3_json(
                "start", "--title", title, project_root, "-",
                prompt=launch_prompt(tag, project_root, operator, operator_source),
            )
            thread = launch
            action = "Started"
        elif not thread["latestRunId"]:
            launch = t3_json(
                "send", thread["threadId"], "-",
                prompt=launch_prompt(tag, project_root, operator, operator_source),
            )
            action = "Started run in existing"
        else:
            launch = None

        if launch is not None and not launch["runId"]:
            raise ValueError(f"T3 did not confirm a run for thread {thread['threadId']}")

        pending = state.with_suffix(".tmp")
        pending.write_text(json.dumps({"tag": tag, "threadId": thread["threadId"]}) + "\n")
        pending.replace(state)
        print(f"{action} release thread for {tag}: {thread.get('link') or thread['threadId']}")


if __name__ == "__main__":
    try:
        watch_dir = Path.home() / ".local/share/dagu/t3code-stable-release-watch"
        settings = json.loads((watch_dir / "config.json").read_text())
        check(watch_dir, **settings)
    except (OSError, ValueError, TypeError, KeyError, ElementTree.ParseError, subprocess.SubprocessError) as error:
        sys.exit(f"T3 Code release check failed: {error}")
