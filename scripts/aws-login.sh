#!/usr/bin/env bash
# aws-login.sh
# Bridge the AWS CLI login session into your current shell so Terraform (and any
# other AWS SDK) can authenticate with it.
#
# Why this exists — the failure mode it fixes
#   `aws login` (AWS CLI v2.36+) does not write an access key pair to
#   ~/.aws/credentials. It writes a *short-lived* STS session (~15 min) to
#   ~/.aws/login/cache/ and records only a reference in ~/.aws/config:
#
#       [default]
#       login_session = arn:aws:iam::<account>:root
#
#   The CLI refreshes that token on demand, but Terraform's AWS provider does not
#   do so reliably — it reports "No valid credential sources found" — and any
#   AWS_* variables already exported in your shell take precedence over the login
#   session. Those exported variables expire and are never refreshed by
#   `aws login`, which is why an "ExpiredToken" error arrives *right after* a
#   successful login.
#
#   This script refreshes the login session if needed, then exports the resolved
#   credentials into the calling shell, replacing anything stale.
#
# Usage — it must run inside YOUR shell; a child process cannot export for you.
#   fish:  scripts/aws-login.sh | source
#   bash:  eval "$(scripts/aws-login.sh)"      # or: source scripts/aws-login.sh
#   zsh:   eval "$(scripts/aws-login.sh)"
#
#   Convenience alias for fish (~/.config/fish/config.fish):
#       alias tf-login='scripts/aws-login.sh | source'
#
# Options:
#   --profile NAME   profile to use (default: $AWS_PROFILE, else "default")
#   --no-login       never launch the browser; fail if the session is dead
#   -h, --help       show help
#
# The credentials are short-lived (~15 min). When Terraform starts failing again,
# re-run this script. Later, the durable version of this is a `credential_process`
# profile, which lets the SDK ask the CLI for fresh credentials on every call:
#
#       [profile tf]
#       credential_process = aws configure export-credentials --profile default --format process
#       region = us-east-1
#
#   ...then run Terraform with AWS_PROFILE=tf. The account is a course sandbox and
#   the default profile authenticates as the account root user; that is a
#   deliberate time-crunch shortcut, not the end state.

set -euo pipefail

PROFILE="${AWS_PROFILE:-default}"
DO_LOGIN=1

log() { printf '%s\n' "$*" >&2; }

usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --profile)
      [ $# -ge 2 ] || { log "aws-login.sh: --profile needs a value"; exit 2; }
      PROFILE="$2"
      shift 2
      ;;
    --no-login)
      DO_LOGIN=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log "aws-login.sh: unknown argument: $1"
      usage >&2
      exit 2
      ;;
  esac
done

# `source`d in bash/zsh we apply the exports ourselves; executed (piped to fish's
# `source`, or wrapped in `eval`) we print them for the caller to apply.
SOURCED=0
if [ -n "${BASH_SOURCE[0]:-}" ] && [ "${BASH_SOURCE[0]}" != "$0" ]; then
  SOURCED=1
fi

# Executed with stdout on a terminal means nobody will apply these lines: they get
# printed and the shell stays unauthenticated, which Terraform reports as "No valid
# credential sources found". Fail loudly instead of looking like success.
if [ "$SOURCED" = 0 ] && [ -t 1 ]; then
  log "aws-login.sh: credentials would only be PRINTED, not applied."
  log "  Let your shell execute them:  fish  scripts/aws-login.sh | source"
  log "                                bash  eval \"\$(scripts/aws-login.sh)\""
  log "                                zsh   eval \"\$(scripts/aws-login.sh)\""
  log "  (redirect stdout to a file if you really just want to read them)"
  exit 2
fi

# Ignore credentials already exported in this shell when probing the login
# session: environment variables outrank the profile, so an expired exported
# token would otherwise hide the fact that the login session is perfectly fine.
probe_identity() {
  env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
      -u AWS_SECURITY_TOKEN -u AWS_PROFILE \
      aws sts get-caller-identity --profile "$PROFILE" \
      --query Arn --output text 2>/dev/null || true
}

identity="$(probe_identity)"

if [ -z "$identity" ]; then
  if [ "$DO_LOGIN" = 1 ]; then
    log "==> No valid session for profile '${PROFILE}'; starting 'aws login'"
    aws login --profile "$PROFILE"
    identity="$(probe_identity)"
  fi
  if [ -z "$identity" ]; then
    log "aws-login.sh: could not authenticate profile '${PROFILE}'."
    log "             Run 'aws login --profile ${PROFILE}' yourself, then retry."
    exit 1
  fi
fi

if [ -n "${AWS_SESSION_TOKEN:-}" ] || [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
  log "note: replacing AWS_* credentials already exported in this shell"
fi

if ! output="$(aws configure export-credentials --profile "$PROFILE" --format env)"; then
  log "aws-login.sh: 'aws configure export-credentials' failed for profile '${PROFILE}'."
  log "             Re-run 'aws login --profile ${PROFILE}' and try again."
  exit 1
fi

if ! grep -q '^export AWS_ACCESS_KEY_ID=' <<<"$output"; then
  log "aws-login.sh: unexpected output from 'aws configure export-credentials':"
  log "$output"
  exit 1
fi

# Terraform gets its region from var.aws_region, but other tools (aws s3 ls, the
# bootstrap script) read it from the environment, so export the profile's region
# when it has one.
region="$(aws configure get region --profile "$PROFILE" 2>/dev/null || true)"
if [ -n "$region" ]; then
  output="${output}"$'\n'"export AWS_REGION=${region}"$'\n'"export AWS_DEFAULT_REGION=${region}"
fi

expiration="$(sed -n 's/^export AWS_CREDENTIAL_EXPIRATION=//p' <<<"$output")"
remaining=""
if [ -n "$expiration" ]; then
  if exp_epoch="$(date -d "$expiration" +%s 2>/dev/null)"; then
    minutes=$(( (exp_epoch - $(date +%s)) / 60 ))
    remaining=" (~${minutes} min left)"
  fi
fi

if [ "$SOURCED" = 1 ]; then
  eval "$output"
  log "==> Credentials exported for profile '${PROFILE}'${remaining}"
else
  printf '%s\n' "$output"
  log "==> Credentials for profile '${PROFILE}'${remaining}"
fi

log "    Identity : ${identity}"
log "    Expires  : ${expiration:-unknown}"
log "    Verify   : env | grep '^AWS_ACCESS_KEY_ID'   # must print a line"
log "    Re-run this script when Terraform reports expired credentials."
