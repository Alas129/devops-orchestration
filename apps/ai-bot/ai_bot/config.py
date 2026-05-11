"""Runtime config — read from env vars at startup."""
from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Config:
    # ── secrets (mounted from K8s Secret backed by ExternalSecret) ────────
    slack_signing_secret: str
    anthropic_api_key: str

    # ── runtime ──────────────────────────────────────────────────────────
    model: str                     # e.g. "claude-sonnet-4-5"
    max_tool_iterations: int       # safety: stop after N tool-call rounds
    cluster_name: str              # for context in prompts

    # ── in-cluster service endpoints ────────────────────────────────────
    prom_url: str
    loki_url: str

    @classmethod
    def from_env(cls) -> "Config":
        def required(key: str) -> str:
            v = os.environ.get(key)
            if not v:
                raise RuntimeError(f"required env var {key} is empty")
            return v

        return cls(
            slack_signing_secret=required("SLACK_SIGNING_SECRET"),
            anthropic_api_key=required("ANTHROPIC_API_KEY"),
            model=os.environ.get("CLAUDE_MODEL", "claude-sonnet-4-5"),
            max_tool_iterations=int(os.environ.get("MAX_TOOL_ITERATIONS", "10")),
            cluster_name=os.environ.get("CLUSTER_NAME", "usf-devops-nonprod"),
            prom_url=os.environ.get(
                "PROM_URL",
                "http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090",
            ),
            loki_url=os.environ.get(
                "LOKI_URL",
                "http://loki-stack.monitoring.svc.cluster.local:3100",
            ),
        )
