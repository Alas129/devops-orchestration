"""Anthropic SDK driver — runs the tool-use loop until Claude produces a final answer.

The loop:
  1. Send messages + tool defs to Claude
  2. If the response is `stop_reason == "tool_use"`, dispatch tool calls
  3. Append tool results as a user message
  4. Repeat (up to MAX_TOOL_ITERATIONS for safety)
"""
from __future__ import annotations

import json
import logging
from dataclasses import dataclass

from anthropic import AsyncAnthropic
from anthropic.types import Message

from . import tools
from .config import Config
from .prompts import SYSTEM_PROMPT

log = logging.getLogger(__name__)


@dataclass
class Answer:
    text: str
    tool_calls_made: int
    tools_used: list[str]


async def answer_question(question: str, cfg: Config) -> Answer:
    """Run the tool-use loop until Claude produces a final answer."""
    client = AsyncAnthropic(api_key=cfg.anthropic_api_key)

    messages: list[dict] = [{"role": "user", "content": question}]
    tools_used: list[str] = []

    for iteration in range(cfg.max_tool_iterations):
        resp: Message = await client.messages.create(
            model=cfg.model,
            max_tokens=2048,
            system=SYSTEM_PROMPT,
            tools=tools.TOOL_SCHEMAS,
            messages=messages,
        )

        # Always echo assistant turn back into history.
        messages.append({"role": "assistant", "content": resp.content})

        if resp.stop_reason != "tool_use":
            # Claude is done — extract the text answer.
            text = "".join(b.text for b in resp.content if b.type == "text")
            return Answer(text=text.strip(), tool_calls_made=iteration, tools_used=tools_used)

        # Execute every tool_use block in this turn, in order.
        tool_results: list[dict] = []
        for block in resp.content:
            if block.type != "tool_use":
                continue
            tools_used.append(block.name)
            log.info("tool call: %s(%s)", block.name, json.dumps(block.input)[:200])
            result = await tools.dispatch(
                block.name,
                block.input,
                prom_url=cfg.prom_url,
                loki_url=cfg.loki_url,
            )
            tool_results.append({
                "type": "tool_result",
                "tool_use_id": block.id,
                "content": json.dumps(result, default=str)[:8000],  # trim huge results
            })

        messages.append({"role": "user", "content": tool_results})

    # Safety bail — never let the loop run forever.
    return Answer(
        text=(
            ":warning: I hit my tool-use iteration limit "
            f"({cfg.max_tool_iterations}). Last context above may still help. "
            "Try a more specific question."
        ),
        tool_calls_made=cfg.max_tool_iterations,
        tools_used=tools_used,
    )
