#!/usr/bin/env bash
# Post a Block Kit message to the #devops-alerts Slack channel.
# Webhook URL is fetched from AWS SSM Parameter Store, so the only repo
# requirement is AWS creds (which promotion workflows already have).
#
# Usage:
#   slack-notify.sh START|SUCCESS|FAIL <title> [<details-line-1> [<details-line-2> ...]]
#
# Examples:
#   slack-notify.sh START "nightly-qa: promoting dev → qa" "triggered by $GITHUB_ACTOR"
#   slack-notify.sh SUCCESS "UAT release v1.2.0-rc.1 deployed" "4/4 cosign verified" "ArgoCD will reconcile in ~30s"
#   slack-notify.sh FAIL "promote-prod cosign verify failed" "image: $svc:$tag" "see run: $GITHUB_RUN_URL"
set -euo pipefail

STATE=${1:?missing STATE arg}
TITLE=${2:?missing title}
shift 2

case "$STATE" in
  START)   EMOJI=":hourglass_flowing_sand:" ; COLOR="#dbab09" ; STATE_LABEL="Started" ;;
  SUCCESS) EMOJI=":large_green_circle:"     ; COLOR="#2eb886" ; STATE_LABEL="Success" ;;
  APPROVAL)EMOJI=":raised_hand:"             ; COLOR="#dbab09" ; STATE_LABEL="Awaiting approval" ;;
  FAIL)    EMOJI=":red_circle:"              ; COLOR="#cc0000" ; STATE_LABEL="Failed" ;;
  *) echo "unknown STATE: $STATE (use START|SUCCESS|APPROVAL|FAIL)" >&2 ; exit 2 ;;
esac

WEBHOOK_URL=$(aws ssm get-parameter \
  --name /devops/argocd/slack_webhook_url \
  --with-decryption --region us-east-1 \
  --query Parameter.Value --output text 2>/dev/null || echo "")
if [[ -z "$WEBHOOK_URL" || "$WEBHOOK_URL" == "None" ]]; then
  echo "WARN: slack webhook URL not in SSM at /devops/argocd/slack_webhook_url — skipping notify" >&2
  exit 0   # don't fail the workflow on missing webhook
fi

# Build the context (workflow link, actor, run number) from GitHub env vars
# when available — empty in local testing.
CONTEXT_LINE=""
if [[ -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_RUN_ID:-}" ]]; then
  CONTEXT_LINE="<${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}|view workflow run>"
fi
ACTOR_LINE=""
if [[ -n "${GITHUB_ACTOR:-}" ]]; then
  ACTOR_LINE="actor: \`${GITHUB_ACTOR}\`"
fi

# Build the details block from any extra positional args (one bullet per arg).
DETAILS_JSON=""
if [[ $# -gt 0 ]]; then
  for line in "$@"; do
    # JSON-escape: \, ", newline, tab
    esc=$(printf '%s' "$line" | python3 -c "import sys,json; sys.stdout.write(json.dumps(sys.stdin.read())[1:-1])")
    DETAILS_JSON="${DETAILS_JSON}• ${esc}\\n"
  done
  DETAILS_JSON="${DETAILS_JSON%\\n}"
fi

# JSON-escape the title.
TITLE_ESC=$(printf '%s' "$TITLE" | python3 -c "import sys,json; sys.stdout.write(json.dumps(sys.stdin.read())[1:-1])")

PAYLOAD=$(cat <<JSON
{
  "text": "${EMOJI} ${STATE_LABEL}: ${TITLE_ESC}",
  "attachments": [{
    "color": "${COLOR}",
    "blocks": [
      {"type":"section","text":{"type":"mrkdwn","text":"${EMOJI} *${STATE_LABEL}* — ${TITLE_ESC}"}}
      $([ -n "$DETAILS_JSON" ] && echo ",{\"type\":\"section\",\"text\":{\"type\":\"mrkdwn\",\"text\":\"${DETAILS_JSON}\"}}")
      ,{"type":"context","elements":[
        $([ -n "$ACTOR_LINE" ] && echo "{\"type\":\"mrkdwn\",\"text\":\"${ACTOR_LINE}\"},")
        {"type":"mrkdwn","text":"${CONTEXT_LINE:-_local run_}"}
      ]}
    ]
  }]
}
JSON
)

curl -sS -X POST -H 'Content-Type: application/json' -d "$PAYLOAD" "$WEBHOOK_URL" >/dev/null
echo "slack notified: $STATE - $TITLE"
