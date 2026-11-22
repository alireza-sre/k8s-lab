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
`route53_zone_id`, `acme_email`, `admin_cidrs`, `github_app_slug`), then:

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

- Require a pull request, 1 approval, dismiss stale approvals, require review
  from Code Owners (add a `CODEOWNERS` with your platform team).
- Require status checks: `atlantis/apply`, plus the `checks` workflow jobs
  (`terraform`, `shell`, `packer`, `yaml`).
- Block force pushes; restrict deletions.

With `atlantis/apply` required, a PR can only merge after every planned
project was applied: **apply, then merge**, so `main` always matches what's
deployed. Atlantis is started with `--gh-allow-mergeable-bypass-apply` so
its own pending apply status doesn't block the `mergeable` apply
requirement.

## How a change flows

1. Open a PR. Atlantis autoplans every project whose `when_modified` paths
   changed (layer files, `../common.tfvars`, `../backend.hcl`, the modules it
   uses) and posts one plan comment per layer.
2. Review the plans and approve the PR (`apply_requirements: approved,
   mergeable, undiverged` is enforced server-side).
3. Comment `atlantis apply`. Projects run lowest `execution_order_group`
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
- Anyone who can comment `atlantis apply` on an approved PR can change
  infrastructure. Use `github_team_allowlist` (e.g.
  `platform:plan,platform:apply,platform:unlock`) to restrict commands to a
  team.
