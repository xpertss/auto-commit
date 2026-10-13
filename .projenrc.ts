// .projenrc.ts
import { GitHubActionProject } from '@xpertss/projen-types';

const project = new GitHubActionProject({
  name: 'auto-commit',
  description: 'Stage a folder and, only if it changed, commit and push it',
  dogfood: {
    // Two scenario steps: the "changed" path and the "no-op" path are both
    // load-bearing behavior for this action (a double-commit or a
    // push-when-empty bug is the failure mode a hand-rolled inline-shell
    // alternative is most likely to introduce).
    scenario: [
      {
        name: 'Changed path',
        fixtureSteps: [
          'echo "$(date -u +%Y%m%dT%H%M%SZ)" >> test/fixtures/dogfood-state.txt',
        ],
        inputs: {
          commit_message: 'test: dogfood',
          branches: 'test/dogfood',
        },
        assertions: [
          // step id defaults to a slug of `name` - here "changed-path-0"
          '[ "${{ steps.changed-path-0.outputs.committed }}" = "true" ]',
        ],
      },
      {
        // No fixture change this time - nothing new to commit.
        name: 'No-op path',
        id: 'no-op-check',            // pin an explicit id instead of relying on the default slug
        inputs: {
          commit_message: 'test: dogfood',
          branches: 'test/dogfood',
        },
        assertions: [
          '[ "${{ steps.no-op-check.outputs.committed }}" = "false" ]',
        ],
      },
      {
        // if_behind: skip - force a real non-fast-forward rejection by
        // advancing test/dogfood independently (scratch clone) so this run's
        // push is rejected, then verify the action skips it (succeeds) rather
        // than failing. Also give this run a fresh change so it commits and
        // actually attempts a push.
        name: 'Skip path',
        id: 'skip-path',
        fixtureSteps: [
          `set -euo pipefail
adv="$(mktemp -d)"
# Authenticate the scratch clone explicitly with GITHUB_TOKEN. Cloning the
# workspace origin (git remote get-url origin) does not carry the checkout
# credential into a fresh clone in /tmp, so the advance push died with:
#   fatal: could not read Username for 'https://github.com'
host="\${GITHUB_SERVER_URL#https://}"
git clone -q "https://x-access-token:\${GITHUB_TOKEN}@\${host}/\${GITHUB_REPOSITORY}" "$adv"
(
  cd "$adv"
  git config user.name "dogfood-advance"
  git config user.email "dogfood@example.com"
  git checkout -q test/dogfood
  echo "advance $(date -u +%s)" >> test/fixtures/dogfood-state.txt
  git add -A
  git commit -qm "dogfood: advance test/dogfood"
  git push -q origin HEAD:refs/heads/test/dogfood
)
rm -rf "$adv"
echo "skip $(date -u +%s)" >> test/fixtures/dogfood-skip.txt`,
        ],
        inputs: {
          commit_message: 'test: dogfood',
          branches: 'test/dogfood',
          if_behind: 'skip',
        },
        assertions: [
          '[ "${{ steps.skip-path.outputs.committed }}" = "true" ]',
          '[ "${{ steps.skip-path.outputs.pushed }}" = "false" ]',
          '[ "${{ steps.skip-path.outputs.skipped_branches }}" = "test/dogfood" ]',
        ],
      },
    ],
    cleanup: [
      'git push origin --delete test/dogfood || true',
    ],
  },
});

project.synth();