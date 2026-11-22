#!/usr/bin/python3

"""Start a local T3 thread when T3 Code publishes a new stable version."""

import fcntl
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from urllib.request import Request, urlopen
from xml.etree import ElementTree

UPSTREAM = "https://github.com/pingdotgg/t3code"
LATEST = "https://api.github.com/repos/pingdotgg/t3code/releases/latest"
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
        return max(candidates, key=stable_version)

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
    return f"""I am a T3 Code agent dispatching the local Dagu release workflow configured in thread {operator_source} for operator {operator}.

Update and release wyrd-company/t3code-client for upstream T3 Code {tag}.
Upstream release: {UPSTREAM}/releases/tag/{tag}

Use `git operator set --from {operator_source}` to inherit the Git operator registration.
Work in the t3code-client repo under {project_root}. Read its `main/AGENTS.md` and
`main/docs/technical-designs/releasing.yml`. Fetch client origin/main and create
a worktree from `t3code-client.git` under this project's `worktrees/` folder.
Check for an existing update or release before starting duplicate work.

Follow the repo's T3 Code update procedure, including contract and tool coverage,
fixtures, live checks, and release intents. Land the update through the repo's
review and merge process. Then follow the documented Release and Publish process
and verify publication for the affected units. Surface any gate that requires the operator.
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
            thread = t3_json(
                "start", "--title", title, project_root, "-",
                prompt=launch_prompt(tag, project_root, operator, operator_source),
            )
            if not thread["runId"]:
                raise ValueError(f"T3 created thread {thread['threadId']} without a run")
            action = "Started"

        pending = state.with_suffix(".tmp")
        pending.write_text(json.dumps({"tag": tag, "threadId": thread["threadId"]}) + "\n")
        pending.replace(state)
        print(f"{action} release thread for {tag}: {thread.get('link') or thread['threadId']}")


if __name__ == "__main__":
    try:
        config_home = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
        settings = json.loads((config_home / "dagu/t3code-stable-release-watch.json").read_text())
        state_home = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state")
        check(state_home / "dagu/t3code-stable-release-watch", **settings)
    except (OSError, ValueError, TypeError, KeyError, ElementTree.ParseError, subprocess.SubprocessError) as error:
        sys.exit(f"T3 Code release check failed: {error}")
