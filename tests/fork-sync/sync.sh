#!/usr/bin/env bash
# Exercises fork-sync-run against local bare repositories standing in for the
# upstream and the fork, with gh and ntfy stubbed on PATH (tests/fork-sync/stubs)
# and git wrapped to log its arguments. No network, no real repositories.
# Usage: tests/fork-sync/sync.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# The real git, not the workspace's git shim, which needs an operator to commit
real_git=""
for c in $(type -ap git); do
    if ! grep -q 'git shim' "$c" 2>/dev/null; then real_git=$c; break; fi
done
[ -n "$real_git" ] || { echo "no real git on PATH" >&2; exit 1; }

stubs="$scratch/stubs"
mkdir -p "$stubs"
cp "$root/tests/fork-sync/stubs/gh" "$root/tests/fork-sync/stubs/ntfy" "$stubs/"
cat >"$stubs/git" <<WRAP
#!/usr/bin/env bash
[ -n "\${STUB_GIT_LOG:-}" ] && printf 'git %s\n' "\$*" >>"\$STUB_STATE/git.log"
exec "$real_git" "\$@"
WRAP
chmod +x "$stubs/git"

export PATH="$stubs:$root/bin:$PATH"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export NTFY_TOPIC=test-topic
unset GIT_OPERATOR GIT_CONFIG_COUNT GH_REPO STUB_ISSUES_DISABLED

failures=0
checks=0
check() { # check DESCRIPTION COMMAND...
    local what=$1; shift
    checks=$((checks + 1))
    if "$@" >/dev/null 2>&1; then
        echo "ok   $case_name: $what"
    else
        echo "FAIL $case_name: $what" >&2
        failures=$((failures + 1))
    fi
}

# new_case NAME: an upstream up/repo with one commit and a fork me/repo of it
new_case() {
    case_name=$1
    dir="$scratch/$1"
    export FORK_SYNC_GIT_URL="$dir/remotes" FORK_SYNC_CACHE="$dir/cache" STUB_STATE="$dir/state"
    mkdir -p "$dir/remotes/up" "$dir/remotes/me" "$STUB_STATE"
    echo up/repo >"$STUB_STATE/parent"
    up="$dir/remotes/up/repo.git" fork="$dir/remotes/me/repo.git"
    git init --quiet --bare -b main "$up"
    git clone --quiet "$up" "$dir/up" 2>/dev/null
    commit "$dir/up" README "line one" "upstream: base"
    git clone --quiet --bare "$up" "$fork"
    git clone --quiet "$fork" "$dir/me"
}
# commit CLONE FILE CONTENT MESSAGE: commit and push to the clone's main
commit() {
    printf '%s\n' "$3" >"$1/$2"
    git -C "$1" add "$2"
    git -C "$1" commit --quiet -m "$4"
    git -C "$1" push --quiet origin HEAD:main
}
pull() { git -C "$1" pull --quiet --no-rebase "${2:-origin}" main; }
sync() { # sync: runs fork-sync-run, leaving its status in rc and output in out
    rc=0
    out=$(STUB_GIT_LOG=1 fork-sync-run up/repo me/repo 2>&1) || rc=$?
    printf '%s\n' "$out" >>"$dir/run.log"
}
head_of() { git --git-dir="$1" rev-parse refs/heads/main; }
tags_of() { git --git-dir="$1" tag --list 'fork-sync/*'; }
is() { [ "$1" = "$2" ]; }
logged() { grep -Fq -- "$2" "$STUB_STATE/$1.log"; }
not_logged() { ! grep -Fq -- "$2" "$STUB_STATE/$1.log" 2>/dev/null; }
count() { grep -Fc -- "$2" "$STUB_STATE/$1.log" 2>/dev/null || true; }
issue() { jq -r "$1" "$STUB_STATE/issues.json"; }

# --- skip on another ref: the DAG's precondition
case_name=dag
home="$scratch/dagu-home"
mkdir -p "$home"
for ref in refs/heads/main refs/heads/feat/x refs/tags/1.0.0; do
    [ "$ref" = refs/heads/main ] && state=succeeded || state=skipped
    dry=$(dagu dry --dagu-home "$home" "$root/sub-dags/fork-sync.yml" -- \
        UPSTREAM=up/repo FORK=me/repo "REF=$ref" 2>&1) || true
    check "REF=$ref: sync $state" grep -Fq -- "─sync [$state]" <<<"$dry"
    check "REF=$ref: run succeeds" grep -Fq 'Result: Succeeded' <<<"$dry"
done

# --- not behind: the fork has upstream's main, and a commit of its own
new_case not-behind
commit "$dir/me" fork.txt mine "fork: own change"
before=$(head_of "$fork")
sync
check "exits 0" is "$rc" 0
check "says nothing to do" grep -q 'not behind' <<<"$out"
check "asks for the comparison" logged gh "gh api repos/me/repo/compare/up:main...main"
check "no merge-upstream" not_logged gh merge-upstream
check "fork unchanged" is "$(head_of "$fork")" "$before"
check "no clone" test ! -e "$FORK_SYNC_CACHE"

# --- fast-forward: the fork has no commits of its own
new_case fast-forward
commit "$dir/up" up.txt new "upstream: new"
sync
check "exits 0" is "$rc" 0
check "calls merge-upstream for main" logged gh "gh api -X POST repos/me/repo/merge-upstream -f branch=main"
check "fork is upstream" is "$(head_of "$fork")" "$(head_of "$up")"
check "no clone" test ! -e "$FORK_SYNC_CACHE"
check "no push" not_logged git "push"

# --- rebase: fork commits on top, backup tag, lease
new_case rebase
commit "$dir/me" fork.txt mine "fork: own change"
old=$(head_of "$fork")
commit "$dir/up" up.txt new "upstream: new"
sync
new=$(head_of "$fork")
check "exits 0" is "$rc" 0
check "no merge-upstream" not_logged gh merge-upstream
check "fork's parent is upstream main" is "$(git --git-dir="$fork" rev-parse "$new^")" "$(head_of "$up")"
check "fork commit kept" is "$(git --git-dir="$fork" log -1 --format=%s "$new")" "fork: own change"
check "backup tag pushed" grep -Eq '^fork-sync/backup-[0-9]{8}T[0-9]{6}Z$' <<<"$(tags_of "$fork")"
check "backup tag is the old fork head" is "$(git --git-dir="$fork" rev-parse "$(tags_of "$fork")^{commit}")" "$old"
check "pushed with the lease" logged git "push --quiet --force-with-lease=main:$old fork $new:refs/heads/main"
check "cache in FORK_SYNC_CACHE" test -f "$FORK_SYNC_CACHE/me/repo.git/HEAD"
check "worktree removed" is "$(git --git-dir="$FORK_SYNC_CACHE/me/repo.git" worktree list | wc -l)" 1
# A second upstream push reuses the cache
commit "$dir/up" up2.txt newer "upstream: newer"
sync
check "second sync exits 0" is "$rc" 0
check "second sync rebased" is "$(git --git-dir="$fork" rev-parse "$(head_of "$fork")^")" "$(head_of "$up")"
check "two backup tags" is "$(tags_of "$fork" | wc -l)" 2

# --- merge commits from "Sync fork" are dropped
new_case merges
commit "$dir/me" a.txt a "fork: a"
commit "$dir/up" up1.txt one "upstream: one"
git -C "$dir/me" remote add upstream "$up"
git -C "$dir/me" fetch --quiet upstream
git -C "$dir/me" merge --quiet --no-ff -m "Merge branch 'main' of up/repo" upstream/main
git -C "$dir/me" push --quiet origin HEAD:main
commit "$dir/me" b.txt b "fork: b"
commit "$dir/up" up2.txt two "upstream: two"
sync
check "exits 0" is "$rc" 0
check "no merge commits left" is "$(git --git-dir="$fork" rev-list --merges --count "$(head_of "$up")..main")" 0
check "fork commits linear on upstream" is "$(git --git-dir="$fork" log --reverse --format=%s "$(head_of "$up")..main" | paste -sd,)" "fork: a,fork: b"
check "upstream is an ancestor" git --git-dir="$fork" merge-base --is-ancestor "$(head_of "$up")" main

# --- conflict: abort, issue, notify, no push
new_case conflict
commit "$dir/me" README "line one, fork" "fork: edit README"
commit "$dir/me" fork.txt mine "fork: own file"
before=$(head_of "$fork")
commit "$dir/up" README "line one, upstream" "upstream: edit README"
sync
check "fails with 2" is "$rc" 2
check "fork unchanged" is "$(head_of "$fork")" "$before"
check "no backup tag" is "$(tags_of "$fork")" ""
check "no push" not_logged git "push"
check "rebase aborted" test ! -d "$FORK_SYNC_CACHE/me/repo.git/worktrees"
check "issue opened" is "$(issue '[.[] | select(.state == "OPEN")] | length')" 1
check "issue labelled" is "$(issue '.[0].labels[0]')" fork-sync
check "issue titled" is "$(issue '.[0].title')" "fork-sync: main conflicts with up/repo"
check "issue has upstream SHA" grep -Fq "$(head_of "$up")" <<<"$(issue '.[0].body')"
check "issue has fork SHA" grep -Fq "$before" <<<"$(issue '.[0].body')"
check "issue lists replayed commits" grep -Fq "fork: own file" <<<"$(issue '.[0].body')"
check "issue lists conflicting file" grep -Fq -- '- `README`' <<<"$(issue '.[0].body')"
check "notified the topic" logged ntfy "https://ntfy.sh/test-topic"
check "notification links the issue" logged ntfy "--click https://github.com/me/repo/issues/1"

# --- duplicate alerts are suppressed while the SHAs match; a later success closes the issue
sync
check "rerun fails" is "$rc" 2
check "rerun says already reported" grep -q 'already reported' <<<"$out"
check "rerun: still one notification" is "$(count ntfy 'ntfy pub')" 1
check "rerun: no comment" is "$(issue '.[0].comments | length')" 0
commit "$dir/up" up.txt new "upstream: another push"
sync
check "new upstream SHA fails" is "$rc" 2
check "new upstream SHA: comment" is "$(issue '.[0].comments | length')" 1
check "new upstream SHA: notifies again" is "$(count ntfy 'ntfy pub')" 2
check "new upstream SHA: still one issue" is "$(issue 'length')" 1
sync
check "rerun after comment: no new alert" is "$(count ntfy 'ntfy pub')" 2
# A person resolves it: the fork's commits, rebased by hand
git -C "$dir/me" fetch --quiet "$up" main
git -C "$dir/me" reset --quiet --hard FETCH_HEAD
echo "line one, upstream and fork" >"$dir/me/README"
git -C "$dir/me" commit --quiet -am "fork: edit README"
git -C "$dir/me" push --quiet --force origin HEAD:main
commit "$dir/up" up3.txt three "upstream: three"
sync
check "sync after the fix exits 0" is "$rc" 0
check "issue closed" is "$(issue '.[0].state')" CLOSED

# --- issues disabled on the fork: the notification carries the details
new_case issues-disabled
commit "$dir/me" README "line one, fork" "fork: edit README"
commit "$dir/up" README "line one, upstream" "upstream: edit README"
STUB_ISSUES_DISABLED=1 sync
check "fails with 2" is "$rc" 2
check "says issues are disabled" grep -q 'cannot use issues' <<<"$out"
check "notifies with the replayed commits" logged ntfy "Replaying:"

# --- lease failure: someone pushes to the fork during the sync
new_case lease
commit "$dir/me" fork.txt mine "fork: own change"
commit "$dir/up" up.txt new "upstream: new"
# The backup tag's push stands in for the moment between fetch and force-push
cat >"$fork/hooks/post-receive" <<'HOOK'
#!/usr/bin/env bash
while read -r _ _ ref; do
    case "$ref" in refs/tags/fork-sync/*)
        c=$(git commit-tree -p main -m "concurrent push" "main^{tree}")
        git update-ref refs/heads/main "$c" ;;
    esac
done
HOOK
chmod +x "$fork/hooks/post-receive"
sync
check "fails with 3" is "$rc" 3
check "says the fork moved" grep -q 'moved past' <<<"$out"
check "concurrent push kept" is "$(git --git-dir="$fork" log -1 --format=%s main)" "concurrent push"
check "no alert" test ! -e "$STUB_STATE/ntfy.log"

if [ "$failures" -ne 0 ]; then
    echo "FAILED: $failures of $checks checks (logs in each case's run.log)" >&2
    exit 1
fi
echo "PASSED: $checks checks"
