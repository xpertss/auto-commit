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
    ],
    cleanup: [
      'git push origin --delete test/dogfood || true',
    ],
  },
});

project.synth();