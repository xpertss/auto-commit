import { GitHubActionProject } from "@xpertss/projen-types";
const project = new GitHubActionProject({
  name: "auto-commit",
  sonarHostUrl: "https://sonarcloud.io",
});
project.synth();