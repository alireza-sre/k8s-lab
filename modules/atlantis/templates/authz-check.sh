#!/bin/sh
# Atlantis authorization check, run as the first step of every plan/apply
# (see repos.yaml). Atlantis's own team allowlist only works for GitHub
# organizations; this works for personal accounts too.
#
#   plan:  the PR author must be authorized (user or PR bot). A plan run from
#          a comment with extra Terraform arguments (after --) also requires
#          the commenter to be an authorized user. Autoplans and argument-free
#          `atlantis plan` comments only plan code an authorized author wrote.
#   apply: the commenter must be an authorized user.
#
# Lists live in /etc/atlantis/authz, synced every minute from SSM by the
# host's atlantis-authz-sync timer. Missing lists fail closed.
#
# set -f: logins like "kube-ec2-bot[bot]" must not be expanded as glob patterns.
set -euf

dir=/etc/atlantis/authz

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

in_list() { # in_list <login> <file>
  name="$(lower "$1")"
  [ -n "$name" ] && [ -r "$2" ] || return 1
  # Lists are space-separated logins (no spaces inside a login): split on words.
  # shellcheck disable=SC2013
  for entry in $(cat "$2"); do
    [ "$entry" = "$name" ] && return 0
  done
  return 1
}

deny() {
  echo "authz: DENIED: $*"
  exit 1
}

case "${1:-}" in
  plan)
    in_list "${PULL_AUTHOR:-}" "$dir/pr-authors" ||
      deny "PR author '${PULL_AUTHOR:-}' is not authorized"
    if [ -n "${COMMENT_ARGS:-}" ] && ! in_list "${USER_NAME:-}" "$dir/users"; then
      deny "'${USER_NAME:-}' may not pass extra Terraform arguments"
    fi
    ;;
  apply)
    in_list "${USER_NAME:-}" "$dir/users" ||
      deny "'${USER_NAME:-}' is not authorized to apply"
    ;;
  *)
    echo "usage: authz-check plan|apply" >&2
    exit 2
    ;;
esac

echo "authz: ok ($1 by ${USER_NAME:-?}, PR by ${PULL_AUTHOR:-?})"
