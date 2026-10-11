#!/usr/bin/env bash
# Local functional test harness for auto-commit.sh.
#
# Simulates the action's runtime on a github.com runner using only local
# tooling: a real git repo whose `origin` is a local bare repository and the
# GITHUB_* environment the runner provides. INPUT_* env vars are set here to
# mirror the mapping in action.yml's env: block (which maps the inputs context
# to INPUT_* names for the composite run: step). It exercises:
#
#   changed    - local changes, explicit target branch  -> commit, push
#   no-op      - no local changes                       -> green no-op (no push)
#   current    - local changes, no branches input       -> commit, push to the
#                                                          current branch
#   multi      - local changes, two target branches     -> one commit on both
#   folder     - changes in and out of `folder`         -> only the folder
#   stack      - second change after a first commit     -> second commit stacks
#   identity   - custom commit_user_name/email          -> author overridden
#   behind     - if_behind off (fail, default) vs on (skip): moved branch,
#                unchanged branch, non-NFF rejection, two branches one moved,
#                bogus value, and the no-op path
#   plus       - validation failures (detached without branches, bad branch,
#                empty branches)
#
# Usage: bash test/local-test.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/auto-commit.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
note() { printf '\n== %s ==\n' "$*"; }
ok()   { PASS=$((PASS + 1)); printf '  PASS %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*"; }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1: expected=[$2] actual=[$3]"; fi; }
assert() { assert_eq "$@"; }
get_out()   { sed -n "s/^$1=//p" "$OUT" | head -n1; }

DEFAULT_AUTHOR='github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>'

# --- static consistency: action.yml env: block covers all auto-commit.sh INPUT_* reads ---
note "static consistency (action.yml env: block vs auto-commit.sh INPUT_* reads)"
ACTION_YML="${REPO_ROOT}/action.yml"
env_keys=$(grep -E '^\s+INPUT_[A-Z_]+:' "$ACTION_YML" | grep -oE 'INPUT_[A-Z_]+' | sort)
script_reads=$(grep -oE 'INPUT_[A-Z_]+' "$SCRIPT" | sort -u)
assert_eq "action.yml env: block provides exactly the INPUT_* vars auto-commit.sh reads" "$script_reads" "$env_keys"

# --- git fixtures: a base bare origin with an initial `main` commit ----------
# Each scenario gets an isolated copy so a push in one can't leak into another.
git init -q --bare "$TMP/base-origin.git"
git init -q -b main "$TMP/seed"
(
  cd "$TMP/seed"
  git config user.name t; git config user.email t@example.com
  echo base > base.txt
  mkdir -p sub && echo inner > sub/inner.txt
  git add -A; git commit -qm "initial"
  git remote add origin "$TMP/base-origin.git"
  git push -q origin main
)

# Prepare a scenario workdir. $1 = label, $2 = change: none|fixture|both
run_scenario() {
  local label="$1" change="$2"
  WORK="$TMP/work-$label"; OUT="$TMP/out-$label.txt"; ERR="$TMP/err-$label.log"
  cp -r "$TMP/base-origin.git" "$TMP/origin-$label.git"
  git clone -q "$TMP/origin-$label.git" "$WORK"
  ( cd "$WORK"; git config user.name t; git config user.email t@example.com )
  case "$change" in
    fixture) echo "change-$label" > "$WORK/fixture.txt" ;;
    both)    echo "change-$label" > "$WORK/outside.txt"; echo "change-$label" >> "$WORK/sub/inner.txt" ;;
  esac
  : > "$OUT"; : > "$ERR"
}

# Invoke the script with a given input set. Runs under a clean env list.
# $1 = workdir, $2 = outputs file, $3 = combined output file, then INPUT_* args.
# Combined stdout+stderr is captured into $3 so assertions can check notices,
# error messages, and the push output (which the hard-failure path to stderr).
run_action() {
  local work="$1" out="$2" err="$3"
  shift 3
  env GITHUB_WORKSPACE="$work" GITHUB_OUTPUT="$out" "$@" \
    INPUT_COMMIT_MESSAGE="test: dogfood" \
    bash "$SCRIPT" > "$err" 2>&1
}

remote_sha() { # <origin.git> <ref>
  git -C "$1" rev-parse -q --verify "refs/heads/$2" 2>/dev/null || true
}

# Advance the remote's <branch> past the current workdir HEAD by committing
# <extra> on a throwaway clone and pushing it. Simulates another run merging
# to the remote branch between this run's checkout and its push.
# $1 = origin.git, $2 = branch, $3 = extra file written in the clone.
advance_remote() {
  local origin="$1" branch="$2" extra="$3" adv
  adv="$TMP/adv-$(basename "$origin")"
  git clone -q "$origin" "$adv"
  (
    cd "$adv"
    git config user.name t; git config user.email t@example.com
    git checkout -q "$branch"
    echo "advance" > "$extra"
    git add -A; git commit -qm "advance"
    git push -q origin "HEAD:refs/heads/$branch"
  )
  rm -rf "$adv"
}

# --- scenario: changed (explicit target branch, detached checkout) ----------
note "changed path (fixture change, explicit branches, detached HEAD)"
run_scenario changed fixture
git -C "$WORK" checkout -q --detach
set +e
run_action "$WORK" "$OUT" "$ERR" INPUT_BRANCHES="test/dogfood"
rc=$?
set -e
assert_eq "exit 0" "0" "$rc"
assert_eq "committed" "true" "$(get_out committed)"
assert_eq "pushed" "true" "$(get_out pushed)"
assert_eq "remote branch created at HEAD" "$(git -C "$WORK" rev-parse HEAD)" "$(remote_sha "$TMP/origin-changed.git" test/dogfood)"
assert_eq "commit author" "$DEFAULT_AUTHOR" "$(git -C "$WORK" log -1 --format='%an <%ae>')"

# --- scenario: no-op (second invocation, same workdir) ----------------------
note "no-op path (no new changes, same workdir)"
: > "$OUT"; : > "$ERR"
set +e
run_action "$WORK" "$OUT" "$ERR" INPUT_BRANCHES="test/dogfood"
rc=$?
set -e
assert_eq "exit 0" "0" "$rc"
assert_eq "committed" "false" "$(get_out committed)"
assert_eq "pushed" "false" "$(get_out pushed)"
assert_eq "remote branch unchanged" "$(git -C "$WORK" rev-parse HEAD)" "$(remote_sha "$TMP/origin-changed.git" test/dogfood)"

# --- scenario: current branch (no branches input) ----------------------------
note "current-branch path (fixture change, no branches input)"
run_scenario current fixture
set +e
run_action "$WORK" "$OUT" "$ERR"
rc=$?
set -e
assert_eq "exit 0" "0" "$rc"
assert_eq "committed" "true" "$(get_out committed)"
assert_eq "pushed" "true" "$(get_out pushed)"
assert_eq "main advanced to HEAD" "$(git -C "$WORK" rev-parse HEAD)" "$(remote_sha "$TMP/origin-current.git" main)"

# --- scenario: multi-branch ---------------------------------------------------
note "multi-branch path (one commit on two branches)"
run_scenario multi fixture
set +e
run_action "$WORK" "$OUT" "$ERR" INPUT_BRANCHES="test/dogfood test/other"
rc=$?
set -e
assert_eq "exit 0" "0" "$rc"
assert_eq "committed" "true" "$(get_out committed)"
head_sha="$(git -C "$WORK" rev-parse HEAD)"
assert_eq "test/dogfood at HEAD" "$head_sha" "$(remote_sha "$TMP/origin-multi.git" test/dogfood)"
assert_eq "test/other at HEAD" "$head_sha" "$(remote_sha "$TMP/origin-multi.git" test/other)"

# --- scenario: folder ----------------------------------------------------------
note "folder path (only the folder is staged)"
run_scenario folder both
set +e
run_action "$WORK" "$OUT" "$ERR" INPUT_FOLDER="sub"
rc=$?
set -e
assert_eq "exit 0" "0" "$rc"
assert_eq "committed" "true" "$(get_out committed)"
assert_eq "commit touches only sub/inner.txt" "sub/inner.txt" "$(git -C "$WORK" diff-tree --no-commit-id --name-only -r HEAD)"
assert_eq "outside.txt left untracked" "?? outside.txt" "$(git -C "$WORK" status --porcelain -- outside.txt)"

# --- scenario: stack (second commit on top of the first) ----------------------
note "stack path (second change, second commit)"
run_scenario stack fixture
set +e
run_action "$WORK" "$OUT" "$ERR" INPUT_BRANCHES="test/dogfood"
rc=$?
set -e
assert_eq "first run committed" "true" "$(get_out committed)"
echo "second-change" >> "$WORK/fixture.txt"
: > "$OUT"; : > "$ERR"
run_action "$WORK" "$OUT" "$ERR" INPUT_BRANCHES="test/dogfood"
rc=$?
set -e
assert_eq "second run exit 0" "0" "$rc"
assert_eq "second run committed" "true" "$(get_out committed)"
assert_eq "branch has two dogfood commits" "2" "$(git -C "$TMP/origin-stack.git" rev-list --count 'main..refs/heads/test/dogfood')"

# --- scenario: identity override ------------------------------------------------
note "identity path (custom commit_user_name/email)"
run_scenario identity fixture
set +e
run_action "$WORK" "$OUT" "$ERR" INPUT_BRANCHES="test/dogfood" \
  INPUT_COMMIT_USER_NAME="Jane Doe" INPUT_COMMIT_USER_EMAIL="jane@example.com"
rc=$?
set -e
assert_eq "exit 0" "0" "$rc"
assert_eq "commit author overridden" "Jane Doe <jane@example.com>" "$(git -C "$WORK" log -1 --format='%an <%ae>')"

# --- scenario: S1 off (fail, default) + branch moved on -----------------------
note "S1: if_behind unset (fail), branch moved on -> hard failure, remote unchanged"
run_scenario s1 fixture
advance_remote "$TMP/origin-s1.git" main extra-s1.txt
before_main="$(remote_sha "$TMP/origin-s1.git" main)"
set +e
run_action "$WORK" "$OUT" "$ERR" INPUT_BRANCHES="main"
rc=$?
set -e
assert_eq "exit non-zero" "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"
assert_eq "committed" "true" "$(get_out committed)"
assert_eq "pushed" "false" "$(get_out pushed)"
assert_eq "skipped_branches empty" "" "$(get_out skipped_branches)"
assert_eq "remote main unchanged" "$before_main" "$(remote_sha "$TMP/origin-s1.git" main)"

# --- scenario: S2 skip + branch moved on ---------------------------------------
note "S2: if_behind=skip, branch moved on -> success, pushed=false, skipped=main"
run_scenario s2 fixture
advance_remote "$TMP/origin-s2.git" main extra-s2.txt
before_main="$(remote_sha "$TMP/origin-s2.git" main)"
set +e
run_action "$WORK" "$OUT" "$ERR" INPUT_BRANCHES="main" INPUT_IF_BEHIND="skip"
rc=$?
set -e
assert_eq "exit 0" "0" "$rc"
assert_eq "committed" "true" "$(get_out committed)"
assert_eq "pushed" "false" "$(get_out pushed)"
assert_eq "skipped_branches" "main" "$(get_out skipped_branches)"
assert_eq "remote main unchanged" "$before_main" "$(remote_sha "$TMP/origin-s2.git" main)"
assert "logs a skip notice" "1" "$(grep -q 'moved on since checkout' "$ERR" && echo 1 || echo 0)"

# --- scenario: S3 skip + branch not moved --------------------------------------
note "S3: if_behind=skip, branch not moved -> normal push, pushed=true"
run_scenario s3 fixture
set +e
run_action "$WORK" "$OUT" "$ERR" INPUT_BRANCHES="main" INPUT_IF_BEHIND="skip"
rc=$?
set -e
assert_eq "exit 0" "0" "$rc"
assert_eq "committed" "true" "$(get_out committed)"
assert_eq "pushed" "true" "$(get_out pushed)"
assert_eq "skipped_branches empty" "" "$(get_out skipped_branches)"
assert_eq "main advanced to HEAD" "$(git -C "$WORK" rev-parse HEAD)" "$(remote_sha "$TMP/origin-s3.git" main)"

# --- scenario: S4 skip + non-NFF rejection (remote-reject hook) ---------------
note "S4: if_behind=skip, remote-reject hook -> hard failure ([remote rejected])"
run_scenario s4 fixture
cat > "$TMP/origin-s4.git/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
echo "denied by pre-receive" >&2
exit 1
HOOK
chmod +x "$TMP/origin-s4.git/hooks/pre-receive"
set +e
run_action "$WORK" "$OUT" "$ERR" INPUT_BRANCHES="main" INPUT_IF_BEHIND="skip"
rc=$?
set -e
assert_eq "exit non-zero" "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"
assert_eq "committed" "true" "$(get_out committed)"
assert_eq "pushed" "false" "$(get_out pushed)"
assert_eq "skipped_branches empty" "" "$(get_out skipped_branches)"
assert "reports [remote rejected]" "1" "$(grep -q 'remote rejected' "$ERR" && echo 1 || echo 0)"

# --- scenario: S5 skip + two branches, one moved ------------------------------
note "S5: if_behind=skip, two branches, main moved -> test/dogfood pushed, main skipped"
run_scenario s5 fixture
advance_remote "$TMP/origin-s5.git" main extra-s5.txt
before_main="$(remote_sha "$TMP/origin-s5.git" main)"
set +e
run_action "$WORK" "$OUT" "$ERR" INPUT_BRANCHES="main test/dogfood" INPUT_IF_BEHIND="skip"
rc=$?
set -e
assert_eq "exit 0" "0" "$rc"
assert_eq "committed" "true" "$(get_out committed)"
assert_eq "pushed" "false" "$(get_out pushed)"
assert_eq "skipped_branches" "main" "$(get_out skipped_branches)"
head_sha="$(git -C "$WORK" rev-parse HEAD)"
assert_eq "test/dogfood pushed to HEAD" "$head_sha" "$(remote_sha "$TMP/origin-s5.git" test/dogfood)"
assert_eq "main unchanged" "$before_main" "$(remote_sha "$TMP/origin-s5.git" main)"

# --- scenario: S6 bogus if_behind (input validation) ---------------------------
note "S6: if_behind=bogus -> input validation failure, nothing staged"
run_scenario s6 fixture
set +e
run_action "$WORK" "$OUT" "$ERR" INPUT_BRANCHES="main" INPUT_IF_BEHIND="bogus"
rc=$?
set -e
assert_eq "exit non-zero" "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"
assert "reports if_behind error" "1" "$(grep -q "must be 'fail' or 'skip'" "$ERR" && echo 1 || echo 0)"
assert "fixture still untracked (not staged)" "?? fixture.txt" "$(git -C "$WORK" status --porcelain)"

# --- scenario: S7 no-op unchanged regardless of if_behind ----------------------
note "S7: no-op path unchanged regardless of if_behind"
run_scenario s7 none
set +e
run_action "$WORK" "$OUT" "$ERR" INPUT_BRANCHES="main" INPUT_IF_BEHIND="skip"
rc=$?
set -e
assert_eq "exit 0" "0" "$rc"
assert_eq "committed" "false" "$(get_out committed)"
assert_eq "pushed" "false" "$(get_out pushed)"
assert_eq "skipped_branches empty" "" "$(get_out skipped_branches)"

# --- validation: detached HEAD without branches --------------------------------
note "validation (detached HEAD, no branches input)"
run_scenario detached none
git -C "$WORK" checkout -q --detach
set +e
run_action "$WORK" "$OUT" "$ERR"
rc=$?
set -e
assert_eq "exits non-zero" "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"
assert "reports detached-HEAD error" "1" "$(grep -q 'the checkout is detached' "$ERR" && echo 1 || echo 0)"

# --- validation: invalid branch name -------------------------------------------
note "validation (invalid branch name)"
run_scenario badbranch none
set +e
run_action "$WORK" "$OUT" "$ERR" INPUT_BRANCHES="bad/../branch"
rc=$?
set -e
assert_eq "exits non-zero" "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"
assert "reports branch error" "1" "$(grep -q 'not a valid git branch name' "$ERR" && echo 1 || echo 0)"

# --- validation: empty branches ---------------------------------------------------
note "validation (branches input empty after trimming)"
run_scenario emptybranches none
set +e
run_action "$WORK" "$OUT" "$ERR" INPUT_BRANCHES="   "
rc=$?
set -e
assert_eq "exits non-zero" "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"
assert "reports empty-branches error" "1" "$(grep -q 'empty after trimming' "$ERR" && echo 1 || echo 0)"

# --- summary -------------------------------------------------------------------
printf '\n== RESULT: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
