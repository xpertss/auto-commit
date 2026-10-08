#!/usr/bin/env bash
# auto-commit.sh — stage a folder and, only if it changed, commit and push it.
#
# Invoked by action.yml (composite action). Runtime dependencies: bash and
# git, both preinstalled on github.com-hosted runners. No gh and no token
# input: the push authenticates through the credential actions/checkout
# embedded in the origin URL, so the caller job needs `contents: write`.
#
# Security invariants (see README.md, "Security model"):
#   - the only network call is `git push origin HEAD:refs/heads/<branch>` for
#     each `branches` entry - never force, never tags, never other refs.
#   - the commit message is written to a file, never placed on a command line.
#   - `set -x` must never be enabled in this script or by callers.

set -euo pipefail

# Operate on the workspace regardless of the current directory.
cd "${GITHUB_WORKSPACE:-.}"

DEFAULT_NAME='github-actions[bot]'
DEFAULT_EMAIL='41898282+github-actions[bot]@users.noreply.github.com'

# --- inputs ----------------------------------------------------------------

commit_message="${INPUT_COMMIT_MESSAGE:?missing required input: commit_message}"
folder="${INPUT_FOLDER:-.}"
branches="${INPUT_BRANCHES:-}"
commit_user_name="${INPUT_COMMIT_USER_NAME:-$DEFAULT_NAME}"
commit_user_email="${INPUT_COMMIT_USER_EMAIL:-$DEFAULT_EMAIL}"

log() {
  echo "[auto-commit] $*"
}

# Write the action outputs (all single-line values).
write_outputs() {
  {
    echo "committed=$1"
    echo "pushed=$2"
  } >> "$GITHUB_OUTPUT"
}

# --- resolve target branches ------------------------------------------------

if [[ -n "$branches" ]]; then
  read -r -a targets <<< "$branches"
  if [[ ${#targets[@]} -eq 0 ]]; then
    echo "::error::'branches' input is empty after trimming" >&2
    exit 1
  fi
else
  current="$(git branch --show-current)"
  if [[ -z "$current" ]]; then
    echo "::error::the checkout is detached (no current branch) and no 'branches' input was given" >&2
    exit 1
  fi
  targets=("$current")
fi

for target in "${targets[@]}"; do
  if ! git check-ref-format --branch "$target" >/dev/null; then
    echo "::error::'$target' is not a valid git branch name" >&2
    exit 1
  fi
done

# --- stage & check (the no-op path) -------------------------------------------

git add -A -- "$folder"
if git diff --staged --quiet; then
  log "No changes under '$folder'; nothing to commit or push."
  write_outputs false false
  exit 0
fi

# --- commit -------------------------------------------------------------------

# Write the message to a file: avoids quoting bugs and keeps it out of the
# process list.
if [[ -n "${RUNNER_TEMP:-}" ]]; then
  msg_file="${RUNNER_TEMP}/auto-commit-commit-message.txt"
else
  msg_file="$(mktemp)"
fi
printf '%s\n' "$commit_message" > "$msg_file"

# -c flags keep the identity local to this commit; gpgsign is forced off so a
# runner-level signing config cannot fail the run.
git -c user.name="$commit_user_name" -c user.email="$commit_user_email" \
  -c commit.gpgsign=false commit -F "$msg_file"
commit_sha="$(git rev-parse HEAD)"
rm -f "$msg_file"
log "Committed $commit_sha."

# --- push -----------------------------------------------------------------------

# No force-push: a target branch that moved on the remote is a visible failure,
# never a clobber.
for target in "${targets[@]}"; do
  log "Pushing to '$target'."
  git push origin "HEAD:refs/heads/$target"
done

write_outputs true true
log "Done: committed='$commit_sha' targets='${targets[*]}'"
