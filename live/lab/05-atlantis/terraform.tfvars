acme_email = "platform@fieldstonecloud.net"

# Your office/VPN egress IPs for the UI. GitHub webhook ranges are added automatically.
admin_cidrs = ["31.146.76.107/32"]

github_app_slug = "k8s-lab-atlantis"

# Who may drive Atlantis (GitHub logins, case-insensitive). Edit and apply this
# layer: takes effect within a minute; the instance is not replaced.
authorized_users = ["alireza-sre"]

# Bots whose PRs may be planned but never applied (see docs/github-actions.md).
authorized_pr_bots = ["k8s-lab-bot[bot]"]

# Solo account: GitHub won't let you approve your own PR, so "approved" would
# block every apply. Add it once a second person reviews.
apply_requirements = ["mergeable", "undiverged"]

# Organizations only: Atlantis's built-in team allowlist (needs the Members permission).
# github_team_allowlist = "platform:plan,platform:apply,platform:unlock"
