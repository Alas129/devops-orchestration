"""FastAPI entry point. Receives Slack slash commands, answers via Claude.

Slack timeout for slash commands is 3 seconds, but tool-use loops typically
take 5-30s. So we ACK immediately with a "thinking..." message, then handle
the real work in a background task and POST the final answer to the user's
`response_url`.
"""
from __future__ import annotations

import asyncio
import logging
from collections import Counter
from urllib.parse import parse_qs

from fastapi import BackgroundTasks, FastAPI, HTTPException, Request, Response

from .claude import answer_question
from .config import Config
from .slack import answer_blocks, post_followup, thinking_response, verify_signature

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s — %(message)s")
log = logging.getLogger("ai-bot")

app = FastAPI(title="usf-devops AI bot", docs_url=None, redoc_url=None)

# Read config once at import; fail-fast on missing env.
CFG = Config.from_env()
log.info("ai-bot starting with model=%s cluster=%s", CFG.model, CFG.cluster_name)


@app.get("/healthz", include_in_schema=False)
async def healthz() -> dict:
    return {"ok": True, "model": CFG.model}


@app.get("/livez", include_in_schema=False)
async def livez() -> dict:
    return {"ok": True}


@app.post("/slack/command")
async def slack_command(request: Request, background: BackgroundTasks) -> dict:
    raw = await request.body()
    ts = request.headers.get("x-slack-request-timestamp", "")
    sig = request.headers.get("x-slack-signature", "")
    if not verify_signature(
        signing_secret=CFG.slack_signing_secret,
        timestamp=ts,
        signature=sig,
        body=raw,
    ):
        log.warning("rejected request with bad signature")
        raise HTTPException(status_code=401, detail="invalid Slack signature")

    form = {k: v[0] for k, v in parse_qs(raw.decode()).items()}
    question = (form.get("text") or "").strip()
    response_url = form.get("response_url")
    user = form.get("user_name", "someone")

    if not question:
        return {
            "response_type": "ephemeral",
            "text": "usage: `/ai <your question>` — e.g. `/ai why is dev-auth-svc degraded?`",
        }
    if not response_url:
        return {"response_type": "ephemeral", "text": ":warning: missing response_url; can't follow up"}

    log.info("question from %s: %s", user, question)
    background.add_task(_resolve, question, response_url)
    return thinking_response(question)


async def _resolve(question: str, response_url: str) -> None:
    """Background task: invoke Claude with tool-use, then POST final answer."""
    try:
        answer = await answer_question(question, CFG)
    except Exception:
        log.exception("answer_question failed")
        await post_followup(
            response_url,
            ":x: I hit an unexpected error answering that. Check the ai-bot pod logs.",
        )
        return

    tool_summary = _tool_summary(answer.tool_calls_made, answer.tools_used)
    await post_followup(
        response_url,
        answer.text,  # plain-text fallback for clients that don't render blocks
        blocks=answer_blocks(answer.text, tool_summary=tool_summary),
    )


def _tool_summary(count: int, tools_used: list[str]) -> str:
    if count == 0:
        return "answered without consulting cluster"
    breakdown = ", ".join(f"{name}×{n}" for name, n in Counter(tools_used).most_common())
    return f"{count} tool call{'s' if count != 1 else ''} — {breakdown}"
