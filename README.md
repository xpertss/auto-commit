# auto-commit

A first-party composite action (replacement for
[stefanzweifel/git-auto-commit-action](https://github.com/stefanzweifel/git-auto-commit-action))
that stages a folder and, **only if it changed**, commits it and pushes the
commit to one or more branches.

```yaml
- uses: xpertss/auto-commit@<ref>
  with:
    commit_message: "chore: update code index"
```

`<ref>` is a commit SHA in machine-managed (projen-generated) workflows or a
tag (e.g. `v1`) in hand-written workflows.

The action is a single committed bash script — no `node`/`index.js` runtime, no
`gh`, no token input — so its whole supply chain is `bash` + `git` on the
runner image.

## Inputs

| Input | Required | Default | Notes |
|---|---|---|---|
| `commit_message` | yes | — | Commit message for the staged change. |
| `folder` | no | `.` | The folder to stage (`git add -A -- <folder>`). `.` (the default) stages the whole tree. |
| `branches` | no | current branch | Space-separated branch names; the one commit is pushed to **each** (`HEAD:refs/heads/<branch>`). When empty, the current branch is used and a detached checkout is a failure. |
| `commit_user_name` | no | `github-actions[bot]` | Name recorded as the commit author and committer. |
| `commit_user_email` | no | `41898282+github-actions[bot]@users.noreply.github.com` | Email recorded as the commit author and committer. |
| `if_behind` | no | `fail` | What to do when a push is rejected because the target branch moved on (non-fast-forward). `fail` (default) fails the step, as before. `skip` leaves that branch alone, reports `pushed: false`, and succeeds. Use `skip` only for content a later run on the newer branch will regenerate (see "Generated content and racing pushes"). |

Identity semantics: `commit_user_name`/`commit_user_email` affect commit
metadata only (author **and** committer are set to the same identity via
`git -c`). The default identity is `github-actions[bot]` so bot-based
automation (auto-approve, branch protection, authorship rules) behaves the
same as with the original action.

## Outputs

| Output | Meaning |
|---|---|
| `committed` | `true` when a commit was created, `false` when nothing was staged. |
| `pushed` | `true` only when **every** target branch accepted the push; `false` when nothing was staged, or a push was skipped or rejected. |
| `skipped_branches` | Space-separated target branches whose push was skipped as non-fast-forward (only with `if_behind: skip`). Empty when none were skipped. |

## Required caller permissions

`permissions: contents: write` on the job. The push authenticates through the
credential `actions/checkout` embeds in the `origin` URL — the action takes no
token input and never places a token on a command line (same model as the
original action).

## Behavior

| Staged change under `folder` | Action |
|---|---|
| none | no commit, no push; outputs `committed: false`, `pushed: false`; **green no-op** |
| yes | commit (identity from inputs, message via temp file) → push `HEAD` to each `branches` target (no force) → outputs `true`, `true` |

- **One commit, N branches:** a single commit is pushed to every `branches`
  entry; all targets end at the same SHA.
- **No force-push:** a target branch that moved on the remote is never a
  clobber. By default it is a visible failure; with `if_behind: skip` it is
  left alone and reported instead (see "Generated content and racing pushes").
- **The no-op path is load-bearing:** running the action twice in one job (as
  the dogfood does) must commit once and no-op the second time — a
  double-commit or push-when-empty bug is the failure mode this design
   specifically guards against.

## Generated content and racing pushes

When a workflow commits **content derived from the tree** (a code index, a
generated manifest, a sync of computed docs), a push that lands while another
run is in flight can be rejected as non-fast-forward — the branch moved on
between this run's checkout and its push. With the default `if_behind: fail`
that shows up as a failed run on `main` after every burst of merges, even
though the branch's final state is already correct (the newer run regenerates
the content from a tree that includes everything).

Use `if_behind: skip` **only** when both are true:

- the committed content is **derived from the tree** (regenerated from whatever
  is checked out), and
- **every push that can move the branch also starts a run that regenerates it**
  (e.g. `on: push` to that branch). Then a skipped push is always covered: the
  newer commit triggers a run whose output reflects the newer tree.

Do **not** use `skip` for hand-authored or one-off commits — nothing will
regenerate those, and a skipped push silently loses the change. `skip` never
changes what is pushed: it only turns a non-fast-forward rejection into a
reported success. Every other push failure (auth, permissions, a protected
branch, the network) still fails the step regardless of `if_behind`.

## Example

The org's current call site (code index update), unchanged:

```yaml
jobs:
  code-index:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v7
      - name: Regenerate the code index
        run: ./scripts/generate-code-index.sh
      - uses: xpertss/auto-commit@v1
        with:
          commit_message: "chore: update code index"
```

Pushing one change to several branches:

```yaml
      - uses: xpertss/auto-commit@v1
        with:
          commit_message: "chore: sync docs"
          folder: docs
          branches: main release/1.4
```

## Testing

`test-dogfood.yml` runs this action **against this repo**, end-to-end, on a
dedicated `test/dogfood` branch: a fixture step creates a real diff, the action
is invoked twice (changed path → must commit and push, then no-op path → must
not), the `committed` output is asserted on both, and a cleanup step
(`if: always()`) deletes the branch.

`test/local-test.sh` is an offline harness (real git repo, local bare
`origin`, the `GITHUB_*`/`INPUT_*` env the composite action provides) covering
the changed/no-op/current-branch/multi-branch/folder/stack/identity paths plus
the validation failures. Run it with `bash test/local-test.sh`.

## Security model

This repo is public; this section is the trust contract.

### Runtime dependency surface (complete)

| Dependency | Source | Why needed |
|---|---|---|
| `bash`, `git` | runner image | stage, commit, push |

No `gh`, no npm/pip install, no `node` runtime, no Docker image, no
`curl | bash`, no base64 blob, no eval of fetched code, no third-party code at
action runtime. This is the whole supply chain. At CI time (not action runtime)
the build/scan workflows additionally use `apt` packages (shellcheck, yamllint)
and the pinned `actionlint` release binary.

### Network surface (complete)

| Endpoint | Direction | Auth | Triggered by |
|---|---|---|---|
| `https://github.com/{o}/{r}.git` | push | `actions/checkout` credential (via the `origin` URL) | `git push --porcelain origin HEAD:refs/heads/<branch>` |

Nothing else. The action makes no other network call — no `gh`/REST API, no
fetch (the caller's `actions/checkout` owns fetching). `if_behind` changes none
of this: no new endpoint, no new env var, no token input; `--porcelain` only
changes the local output format so a non-fast-forward rejection can be detected.

### Env vars read (complete)

`INPUT_*` (action inputs), `GITHUB_WORKSPACE`, `GITHUB_OUTPUT`, `RUNNER_TEMP`.
(`GITHUB_ACTION_PATH` is used by `action.yml` to locate this script.) No other
env is read; no env is dumped to logs. No secret is ever read.

### Token flow

There is **no token input**. `actions/checkout` embeds the job token in the
`origin` remote URL; `git push origin …` authenticates through that. The token
never appears in any command line, is never written to a persistent path, and
is never printed (no `set -x`, no `echo` of credentials). The only requirement
is `contents: write` on the calling job.

### Invariants (what this action will never do)

- no writes to the working tree other than `git add -A -- <folder>`/`git commit`
- no push to any ref other than the `branches` targets (never `--mirror`, never
  a wildcard, never tags)
- no force-push, no tag creation or deletion
- no `gh`/REST API calls, no workflow dispatch, no issue/comment writes
- no reading of secrets
- the commit message is passed via a temp file (`git commit -F`), never on a
  command line; branch names are validated with `git check-ref-format --branch`
  before use

### Residual risks (accepted, with mitigations)

| Risk | Mitigation |
|---|---|
| Runner image drift (`ubuntu-latest`) | the dogfood workflow runs on every PR and on a schedule and would catch a regression; the action uses only basic `bash`/`git` long-stable subcommands |
| Tag mutation (`v1` rewritten) | consumers SHOULD pin by SHA in machine-managed workflows; tag deletion on `main` is blocked by branch protection |
| Third-party **tools** in CI (`actionlint` binary) | pinned release version + SHA-256 recorded in the workflow; upgrades are a reviewed code change, not a silent download |

## How to bump / upgrade consumers

There is no registry: the git repo is the artifact. Releases are cut by
`release.yml` on push to `main` (conventional commits; tag `vX.Y.Z` + GitHub
Release). Consumers:

- **Hand-written workflows** — bump the tag (e.g. `@v1` → `@v2`).
- **Machine-managed (projen-generated) workflows** — pin the commit SHA and
  update it via the consuming repo's `bump` task (resolve latest tag → commit
  SHA → update the `uses:` constant → `npx projen`).

## Out of scope (v1)

- `token` input — the action relies on `actions/checkout`'s credential and the
  job's `contents: write`, matching the original action.
- Tagging (`tagging_message`) — not used by the org.
- `commit_author` separate from `commit_user_name` (actor-based author) —
  author and committer are the same identity by default.
- `skip_fetch`/`skip_checkout`/`head_commit` — the caller's `actions/checkout`
  owns fetching and checkout; the action only stages/commits/pushes.
- `push_options` (e.g. `--force`) — force-push is intentionally unsupported.
- Marketplace listing.

## Differences from the original action

- **Runtime:** the original is a `node20`/`index.js` action; this one is a
  `using: composite` bash action (smaller supply chain, no `node` at runtime).
- **`branch` → `branches`:** the original takes a single `branch` (defaulting
  to `github.head_ref`); this action takes space-separated `branches` and
  pushes one commit to each, defaulting to the current branch.
- **`file_pattern`/`repository` → `folder`:** this action stages a folder with
  `git add -A -- <folder>` (default `.`), rather than a glob pattern.
- **`commit_author` default:** the original defaults the commit author to the
  workflow actor; this action defaults author and committer to
  `github-actions[bot]` (no actor default).
- **Outputs:** the original exposes `changes_detected`/`commit_hash`; this
  action exposes `committed`/`pushed` booleans (no SHA output — the caller can
  read `git rev-parse HEAD` after the step if it needs the hash).
- **No `commit_options`/`add_options`/`status_options`/`push_options`
  passthrough:** the action has fixed, auditable behavior (no `--no-verify`,
  no force-push).
- **No `create_branch`/`tagging_message`/`disable_globbing`/
  `skip_dirty_check`/`skip_fetch`/`skip_checkout`/`internal_git_binary`** —
  none are used by the org; creating a branch is implicit in pushing to a
  ref that does not yet exist.
