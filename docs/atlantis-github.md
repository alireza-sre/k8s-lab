# Connecting Atlantis to GitHub

Atlantis authenticates to GitHub as a **GitHub App** (not a personal token):
scoped to one repository, short-lived installation tokens, comments posted as
the app, and the app delivers webhooks itself (no repo webhook to manage).

Do steps 1 to 4 **before** applying `live/lab/05-atlantis`. The instance reads
its secrets from SSM at boot.

## 1. Pick the hostname

Atlantis needs a public HTTPS URL that GitHub can call, e.g.
`atlantis.example.com`, in a Route 53 public hosted zone you control. Caddy on
the instance gets a Let's Encrypt certificate for it automatically (port 80
is open only for that HTTP-01 challenge and redirects).

## 2. Create the GitHub App

Organisation: **Settings → Developer settings → GitHub Apps → New GitHub App**
(personal account: your profile **Settings → Developer settings**).

| Field | Value |
|---|---|
| GitHub App name | e.g. `kube-ec2-atlantis` (its URL slug is `github_app_slug`) |
| Homepage URL | `https://atlantis.example.com` |
| Webhook → Active | checked |
| Webhook URL | `https://atlantis.example.com/events` |
| Webhook secret | output of `openssl rand -hex 32` (keep it for step 4) |
| SSL verification | enabled |
| Where can this app be installed? | Only on this account |

**Repository permissions** (as Atlantis documents them):

| Permission | Access |
|---|---|
| Administration | Read-only |
| Actions | Read-only (needed for the mergeable check that ignores `atlantis/apply`) |
| Checks | Read and write |
| Commit statuses | Read and write |
| Contents | Read and write |
| Issues | Read and write |
| Metadata | Read-only |
| Pull requests | Read and write |
| Webhooks | Read and write |

**Organization permissions**: Members, read-only (only needed if you use
`github_team_allowlist`).

**Subscribe to events**: Issue comment, Pull request, Pull request review,
Push.

Create the app, then on its page:

1. Note the **App ID**.
2. **Generate a private key** and download the `.pem`.
3. **Install App** → this account → **Only select repositories** → this
   repository. (The installation ID is the number at the end of the
   installation's settings URL; optional, Atlantis can discover it.)

## 3. Store the secrets in SSM

Run with admin credentials in the target account and region. Paths match
`secrets_ssm_prefix = /<project>/<environment>/atlantis`:

```bash
P=/kube-ec2/lab/atlantis
aws ssm put-parameter --name $P/github-app-id         --type String       --value 123456
aws ssm put-parameter --name $P/github-app-key        --type SecureString --value file://kube-ec2-atlantis.2026-11-02.private-key.pem
aws ssm put-parameter --name $P/github-webhook-secret --type SecureString --value '<secret from step 2>'
aws ssm put-parameter --name $P/web-password          --type SecureString --value "$(openssl rand -base64 24)"
shred -u kube-ec2-atlantis.*.private-key.pem   # it now lives only in SSM
```

The UI user is `admin` with the `web-password` above. `/events` is not behind
basic auth; it's protected by the webhook secret (HMAC on every delivery).

## 4. Configure and apply the Atlantis layer (locally)

Edit `live/lab/05-atlantis/terraform.tfvars` (`domain_name`,
`route53_zone_id`, `acme_email`, `admin_cidrs`, `github_app_slug`, and
`authorized_users`: your GitHub login, see
[Who can run Atlantis commands](#who-can-run-atlantis-commands)), then:

```bash
cd live/lab/05-atlantis
terraform init -backend-config=../backend.hcl
terraform apply -var-file=../common.tfvars
```

Port 443 is reachable only from GitHub's published webhook ranges (fetched
from `api.github.com/meta` at plan time) plus `admin_cidrs`. If GitHub adds
ranges, re-apply this layer.

## 5. Verify

```bash
curl -fsS https://atlantis.example.com/healthz          # {"status":"ok"}
aws ssm start-session --target $(terraform output -raw instance_id)
#   sudo journalctl -u atlantis -u caddy -f
#   or CloudWatch Logs group /kube-ec2-lab/atlantis
```

In the app's **Advanced → Recent Deliveries** a `ping` should show 200. Open a
throwaway PR that touches `live/lab/10-network/terraform.tfvars` (e.g. a
comment): Atlantis should autoplan `lab-10-network` and comment the plan.

## 6. Protect `main`

**Settings → Rules → Rulesets → New branch ruleset** targeting `main`:

- Require a pull request. With reviewers: 1 approval, dismiss stale
  approvals, review from Code Owners (add a `CODEOWNERS` file). Alone: 0
  approvals (GitHub doesn't let you approve your own PR).
- Require status checks: `atlantis/apply`, plus the `checks` workflow jobs
  (`terraform`, `shell`, `packer`, `yaml`).
- Block force pushes; restrict deletions.

With `atlantis/apply` required, a PR can only merge after every planned
project was applied: **apply, then merge**, so `main` always matches what's
deployed. Atlantis is started with `--gh-allow-mergeable-bypass-apply` so
its own pending apply status doesn't block the `mergeable` apply
requirement.

## Who can run Atlantis commands

On a public repository anyone can comment on your pull requests, so anyone
could otherwise comment `atlantis apply` on them. Atlantis's
`github_team_allowlist` only works for GitHub organizations, so this setup
checks the user itself: the first step of every plan and apply in the
server-side workflow runs `authz-check` (`modules/atlantis/templates/authz-check.sh`).

| Action | Allowed when |
|---|---|
| plan (autoplan or `atlantis plan` comment) | the PR author is in `authorized_users` or `authorized_pr_bots` |
| plan with extra Terraform arguments (`atlantis plan -- -var …`) | additionally, the commenter is in `authorized_users` |
| apply | the commenter is in `authorized_users` |

Other comment commands are disabled (`ATLANTIS_ALLOW_COMMANDS=version,plan,apply,unlock`).
PRs from forks are never planned (`--allow-fork-prs` is off by default).

The lists are Terraform variables in `live/lab/05-atlantis/terraform.tfvars`:

```hcl
authorized_users   = ["your-github-login"]
authorized_pr_bots = ["kube-ec2-bot[bot]"]
```

They are stored in SSM (`/<project>/<env>/atlantis/authorized-users` and
`authorized-pr-authors`), not in the instance's user data. A timer on the
instance copies them into the container every minute, so changing a list
and applying `05-atlantis` takes effect within a minute without replacing
the instance. If a list can't be read, the previous copy is kept; if there
is none, every command is refused.

A refused command shows up in the PR comment as a failed step with
`authz: DENIED: <reason>`.

For extra protection: **Settings → Moderation options → Interaction limits
→ Limit to repository collaborators** stops strangers from commenting at all
(for up to 6 months at a time).

## How a change flows

1. Open a PR. Atlantis autoplans every project whose `when_modified` paths
   changed (layer files, `../common.tfvars`, `../backend.hcl`, the modules it
   uses) and posts one plan comment per layer.
2. Review the plans. If `apply_requirements` includes `approved` (add it
   once someone else reviews), get the PR approved; `mergeable` and
   `undiverged` are always enforced server-side.
3. Comment `atlantis apply` (as one of `authorized_users`). Projects run lowest `execution_order_group`
   first (10 → 20 → 30 → 40 → 50); a failure aborts later groups.
   `atlantis apply -p lab-30-cluster` is refused while a layer it
   `depends_on` in the same PR is unapplied.
4. Merge. Atlantis releases its locks.

**Cross-layer changes in one PR.** Plans of later layers read the SSM
contract of earlier layers as currently applied. If layer 30 needs a value
that layer 10 introduces in the same PR, apply 10 first and then re-plan:
`atlantis plan -p lab-30-cluster`. Smaller one-layer PRs avoid this.

## Security notes

- The server-side `repos.yaml` (rendered by Terraform, not in the repo)
  allows only the `layered` workflow and forbids custom workflows, so a PR
  cannot make Atlantis run arbitrary commands via `atlantis.yaml`.
- Atlantis' instance role can only read/write state and assume the deployer
  role. It has no Kubernetes credentials.
- Only `authorized_users` can apply, and only PRs by authorized authors are
  planned (see [Who can run Atlantis commands](#who-can-run-atlantis-commands)).
  In an organization you can add Atlantis's own `github_team_allowlist` on
  top.
- A plan runs the PR's Terraform code with the deployer role, so anyone who
  can push branches to this repository can run code with those rights. Keep
  write access to the repository limited to people you'd give the deployer
  role.
