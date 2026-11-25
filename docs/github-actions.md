# GitHub Actions setup

Two workflows live in `.github/workflows/`:

| Workflow | Runs on | Needs |
|---|---|---|
| `checks.yml` | every PR and push to `main` | nothing (no AWS access, read-only token) |
| `node-ami.yml` | weekly schedule, manual dispatch | the `ami-build` environment (AWS via OIDC) and the PR bot app |

Do this after `scripts/bootstrap-backend.sh` (it creates the AWS role used
below) and before the first `node-ami` run.

## 1. The `ami-build` environment (AWS access for Packer)

The `build` job assumes an IAM role through GitHub OIDC, so no AWS keys are
stored in GitHub. The role (`modules/github-oidc-role`, created by
`00-bootstrap`) trusts only `repo:<owner>/<repo>:environment:ami-build`, so
only jobs that run in this environment can assume it.

**Settings → Environments → New environment** → `ami-build`:

- **Deployment branches and tags:** *Selected branches* → `main`. Without
  this, a workflow on any branch could use the environment.
- *(Optional)* **Required reviewers:** yourself, if you want to approve each
  build.
- **Environment variables:**

| Variable | Value |
|---|---|
| `PACKER_ROLE_ARN` | `terraform output -raw github_packer_role_arn` in `live/lab/00-bootstrap` |
| `AWS_REGION` | the region in `live/lab/common.tfvars`, e.g. `eu-central-1` |

## 2. The PR bot (a second GitHub App)

The `propose` job opens a PR that bumps `live/lab/30-cluster/ami.auto.tfvars`.
A PR opened with the built-in `GITHUB_TOKEN` doesn't trigger other workflows,
so `checks.yml` would never run on it and a ruleset requiring those checks
would block the merge. A GitHub App token doesn't have that limitation.

Use a separate app, not the Atlantis one: it needs only two permissions, and
a leaked key then can't post as Atlantis.

1. **Settings → Developer settings → GitHub Apps → New GitHub App**
   - Name: e.g. `kube-ec2-bot` (its login becomes `kube-ec2-bot[bot]`)
   - Homepage URL: the repository URL
   - Webhook: **uncheck Active** (it receives no events)
   - Repository permissions:
     - **Contents: Read and write** (push the `bot/node-ami` branch)
     - **Pull requests: Read and write** (open the PR, add labels)
     - Metadata: Read-only (automatic)
   - Where can this app be installed: **Only on this account**
2. Create it. Note the **App ID** at the top of the app's page.
3. **Generate a private key** (a `.pem` downloads).
4. **Install App** → **Only select repositories** → this repository.
5. **Repository Settings → Secrets and variables → Actions.** These are
   repository-level, not in `ami-build`: the `propose` job doesn't run in
   that environment.

| Tab | Name | Value |
|---|---|---|
| Variables | `BOT_APP_ID` | the App ID |
| Secrets | `BOT_APP_PRIVATE_KEY` | the full `.pem` contents, including the `BEGIN`/`END` lines |

Then delete the `.pem` file.

6. Let Atlantis plan the bot's PRs: add the bot's login to
   `authorized_pr_bots` in `live/lab/05-atlantis/terraform.tfvars` and apply
   that layer. Bots can be planned but never applied; only `authorized_users`
   can apply (see [atlantis-github.md](atlantis-github.md#who-can-run-atlantis-commands)).

**Without a bot app:** remove the `create-github-app-token` step, pass
`token: ${{ secrets.GITHUB_TOKEN }}` to both the checkout and
`create-pull-request` steps, give the job `contents: write` and
`pull-requests: write`, and enable **Settings → Actions → General → Allow
GitHub Actions to create and approve pull requests**. Atlantis still
autoplans (it gets its own webhook), but `checks.yml` won't run on the PR.

## 3. Repository-wide Actions settings (public repo)

**Settings → Actions → General:**

- **Fork pull request workflows from outside collaborators:** *Require
  approval for all external contributors*. Strangers can't run workflows on
  your runners without your click.
- **Workflow permissions:** *Read repository contents and packages
  permissions* (jobs ask for more explicitly).
- Never change the workflows to `pull_request_target`: it runs fork code with
  repository secrets.

**Pin actions to commit SHAs.** A tag or branch reference (`@v4`, `@main`)
runs whatever its owner pushes next, inside jobs that hold AWS credentials or
the bot key. Replace each `uses: owner/action@ref` with the full commit SHA
(keep the version as a comment), and let Dependabot keep them current:

```yaml
# .github/dependabot.yml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
```

## 4. First run

**Actions → node-ami → Run workflow.** Expect about 15 minutes: the build
job ends with the AMI ID in its summary, and `propose` opens
"Node AMI ami-… (Kubernetes v1.36.x)". Atlantis then autoplans
`lab-30-cluster` on that PR.
