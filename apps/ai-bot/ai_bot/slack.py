"""Slack signature verification + response formatting.

We use slash commands (`/ai <question>`) so the only API surface we touch is:
  - inbound: POST /slack/command (signed payload)
  - outbound: POST <response_url>  (no bot token needed)

This avoids the chat:write scope and `slack-sdk` heavyweight client.
"""
from __future__ import annotations

import hashlib
import hmac
import time

import httpx


def verify_signature(
    *,
    signing_secret: str,
    timestamp: str,
    signature: str,
    body: bytes,
) -> bool:
    """Validate the X-Slack-Signature header per Slack's spec.

    https://api.slack.com/authentication/verifying-requests-from-slack
    """
    # Reject requests older than 5 minutes — protects against replay.
    try:
        if abs(time.time() - int(timestamp)) > 300:
            return False
    except ValueError:
        return False

    sig_basestring = f"v0:{timestamp}:".encode() + body
    expected = "v0=" + hmac.new(
        signing_secret.encode(),
        sig_basestring,
        hashlib.sha256,
    ).hexdigest()
    return hmac.compare_digest(expected, signature)


async def post_followup(response_url: str, text: str, *, blocks: list | None = None) -> None:
    """Send a delayed response to the user's slash command.

    Slack's `response_url` accepts POSTs for 30 minutes after the original
    command. We use `replace_original: true` so the "thinking..." placeholder
    gets replaced with the final answer.
    """
    payload: dict = {
        "response_type": "in_channel",
        "replace_original": True,
        "text": text,
    }
    if blocks:
        payload["blocks"] = blocks
    async with httpx.AsyncClient(timeout=20.0) as client:
        r = await client.post(response_url, json=payload)
        r.raise_for_status()


def thinking_response(question: str) -> dict:
    """The immediate (<3s) reply Slack expects from a slash command."""
    return {
        "response_type": "in_channel",
        "text": f":robot_face: Thinking about: *{question}*",
        "blocks": [
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": f":hourglass_flowing_sand: *@ai is investigating*\nQuestion: _{question}_",
                },
            },
        ],
    }


def answer_blocks(answer: str, *, tool_summary: str) -> list:
    """Render the final answer as Slack Block Kit for nicer formatting."""
    return [
        {
            "type": "section",
            "text": {"type": "mrkdwn", "text": f":robot_face: *@ai answer*\n{answer}"},
        },
        {
            "type": "context",
            "elements": [{"type": "mrkdwn", "text": f"_{tool_summary}_"}],
        },
    ]
