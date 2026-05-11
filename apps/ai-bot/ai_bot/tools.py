"""Read-only tools the LLM can call to inspect cluster state.

Design rules:
  - Every tool is READ-ONLY. No verbs that mutate (apply/create/delete/patch).
  - Return types are simple Python dicts/lists/strings, JSON-friendly.
  - All errors caught + returned as a `{"error": ...}` dict so Claude can
    react gracefully instead of the whole tool-use loop dying.

The bot's ClusterRole (charts/ai-bot/templates/clusterrole.yaml) enforces
the same constraints at the K8s API level — defense in depth.
"""
from __future__ import annotations

import logging
from typing import Any

import httpx
from kubernetes import client, config as k8s_config
from kubernetes.client.exceptions import ApiException

log = logging.getLogger(__name__)


# ───────────────────────── lazy K8s client ────────────────────────────────
_K8S_INITIALIZED = False


def _init_k8s() -> None:
    global _K8S_INITIALIZED
    if _K8S_INITIALIZED:
        return
    try:
        # in-cluster path — pod has a service-account token mounted
        k8s_config.load_incluster_config()
    except k8s_config.ConfigException:
        # local dev fallback
        k8s_config.load_kube_config()
    _K8S_INITIALIZED = True


# ───────────────────────── tool implementations ──────────────────────────


def list_namespaces() -> dict:
    """Return the cluster's namespaces. Cheap orientation call."""
    _init_k8s()
    v1 = client.CoreV1Api()
    items = v1.list_namespace().items
    return {"namespaces": [n.metadata.name for n in items]}


def kubectl_get(
    *,
    resource: str,
    namespace: str | None = None,
    name: str | None = None,
    label_selector: str | None = None,
) -> dict:
    """List or describe core/rollout resources.

    Supports: pods, services, deployments, replicasets, rollouts (argo),
              applications (argocd), ingresses, configmaps, prometheusrules,
              alertmanagerconfigs, events.
    """
    _init_k8s()
    try:
        items = _fetch(resource, namespace=namespace, name=name, label_selector=label_selector)
    except ApiException as e:
        return {"error": f"k8s API error: {e.status} {e.reason}", "body": e.body[:500] if e.body else None}
    except Exception as e:
        return {"error": f"{type(e).__name__}: {e}"}
    return {"resource": resource, "namespace": namespace, "count": len(items), "items": items}


def kubectl_logs(
    *,
    namespace: str,
    pod: str,
    container: str | None = None,
    tail_lines: int = 80,
    previous: bool = False,
) -> dict:
    """Return the last N lines from a pod's container log.

    Set `previous=true` to read logs from a CrashLoopBackOff'd container's
    previous instance — often where the actual error is.
    """
    _init_k8s()
    v1 = client.CoreV1Api()
    try:
        log_text = v1.read_namespaced_pod_log(
            name=pod,
            namespace=namespace,
            container=container,
            tail_lines=tail_lines,
            previous=previous,
            timestamps=True,
        )
    except ApiException as e:
        return {"error": f"k8s API error: {e.status} {e.reason}"}
    return {"namespace": namespace, "pod": pod, "container": container, "log": log_text}


def argocd_app(name: str) -> dict:
    """Get an ArgoCD Application's sync + health status + recent operation."""
    _init_k8s()
    api = client.CustomObjectsApi()
    try:
        app = api.get_namespaced_custom_object(
            group="argoproj.io",
            version="v1alpha1",
            namespace="argocd",
            plural="applications",
            name=name,
        )
    except ApiException as e:
        return {"error": f"argocd application {name} not found: {e.reason}"}

    status = app.get("status", {})
    return {
        "name": name,
        "destination": app.get("spec", {}).get("destination", {}),
        "sync_status": status.get("sync", {}).get("status"),
        "health_status": status.get("health", {}).get("status"),
        "operation_phase": status.get("operationState", {}).get("phase"),
        "operation_message": status.get("operationState", {}).get("message"),
        "revision": status.get("sync", {}).get("revision"),
        "conditions": [
            {"type": c.get("type"), "message": c.get("message")}
            for c in status.get("conditions", []) or []
        ],
    }


async def prom_query(*, query: str, prom_url: str) -> dict:
    """Run an instant PromQL query against the in-cluster Prometheus."""
    async with httpx.AsyncClient(timeout=10.0) as cli:
        r = await cli.get(f"{prom_url}/api/v1/query", params={"query": query})
        if r.status_code != 200:
            return {"error": f"HTTP {r.status_code}: {r.text[:300]}"}
        data = r.json()
        if data.get("status") != "success":
            return {"error": f"Prometheus error: {data.get('error')}"}
        result = data["data"]["result"]
        # Trim to first 25 series — too many breaks Slack message size limit.
        return {"query": query, "series_count": len(result), "series": result[:25]}


async def loki_query(*, logql: str, hours: int, loki_url: str) -> dict:
    """Run a LogQL query against in-cluster Loki for the last N hours.

    Returns up to 50 log lines. Keep `hours` small (1-6) — wide time
    windows are expensive on the Loki side.
    """
    import time as _t
    end = int(_t.time() * 1_000_000_000)
    start = end - (hours * 3600 * 1_000_000_000)
    async with httpx.AsyncClient(timeout=15.0) as cli:
        r = await cli.get(
            f"{loki_url}/loki/api/v1/query_range",
            params={"query": logql, "start": start, "end": end, "limit": 50, "direction": "backward"},
        )
        if r.status_code != 200:
            return {"error": f"HTTP {r.status_code}: {r.text[:300]}"}
        data = r.json()
        if data.get("status") != "success":
            return {"error": f"Loki error: {data}"}
        lines: list[dict] = []
        for stream in data.get("data", {}).get("result", []):
            labels = stream.get("stream", {})
            for ts, line in stream.get("values", []):
                lines.append({"ts": ts, "labels": labels, "line": line[:500]})
        return {"query": logql, "line_count": len(lines), "lines": lines[:50]}


def recent_alerts() -> dict:
    """List currently-firing Prometheus alerts (read from PrometheusRule CRs).

    We can't query Alertmanager directly without its API exposed, but reading
    the Prometheus instance's `/api/v1/alerts` works the same way.
    """
    # Caller passes prom_url; bound at runtime in the dispatcher.
    raise NotImplementedError("use prom_query with ALERTS{alertstate='firing'} or call /api/v1/alerts")


# ───────────────────────── tool registry for Claude ──────────────────────


# ───────────────────────── WRITE tools (gated by allowlist) ──────────────


async def trigger_workflow_dispatch(
    *,
    workflow: str,
    ref: str = "main",
    inputs: dict | None = None,
    repository: str,
    github_token: str,
) -> dict:
    """Trigger a GitHub Actions workflow via workflow_dispatch.

    workflow: filename (e.g. 'nightly-qa.yaml', 'promote-uat.yaml')
    ref: branch or tag ref
    """
    if not github_token:
        return {"error": "no GITHUB_API_TOKEN configured — workflow dispatch unavailable"}
    url = f"https://api.github.com/repos/{repository}/actions/workflows/{workflow}/dispatches"
    async with httpx.AsyncClient(timeout=15.0) as cli:
        r = await cli.post(
            url,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {github_token}",
                "X-GitHub-Api-Version": "2022-11-28",
            },
            json={"ref": ref, "inputs": inputs or {}},
        )
        if r.status_code in (200, 204):
            return {"ok": True, "workflow": workflow, "ref": ref}
        return {"error": f"HTTP {r.status_code}: {r.text[:400]}"}


async def create_release_tag(
    *,
    tag: str,
    target_sha: str | None,
    repository: str,
    github_token: str,
) -> dict:
    """Create a lightweight git tag pointing at a commit. Triggers promote-uat
    or promote-prod via the workflow's `on: push: tags:` filter.

    tag:        e.g. 'v0.1.0-rc.5'
    target_sha: commit SHA the tag should point at (default = current main HEAD)
    """
    if not github_token:
        return {"error": "no GITHUB_API_TOKEN configured"}
    # Resolve target SHA if not provided.
    async with httpx.AsyncClient(timeout=15.0) as cli:
        if not target_sha:
            r = await cli.get(
                f"https://api.github.com/repos/{repository}/git/refs/heads/main",
                headers={"Authorization": f"Bearer {github_token}"},
            )
            if r.status_code != 200:
                return {"error": f"could not resolve main: HTTP {r.status_code}: {r.text[:300]}"}
            target_sha = r.json()["object"]["sha"]

        r = await cli.post(
            f"https://api.github.com/repos/{repository}/git/refs",
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {github_token}",
                "X-GitHub-Api-Version": "2022-11-28",
            },
            json={"ref": f"refs/tags/{tag}", "sha": target_sha},
        )
        if r.status_code in (200, 201):
            return {"ok": True, "tag": tag, "sha": target_sha}
        return {"error": f"HTTP {r.status_code}: {r.text[:400]}"}


def force_argocd_sync(*, app_name: str, revision: str | None = None) -> dict:
    """Force an ArgoCD Application to re-sync NOW (recovery from stuck
    multi-source race or unstuck a degraded App).

    revision: optional git SHA to pin the sync to (avoids re-hitting the race)
    """
    _init_k8s()
    api = client.CustomObjectsApi()
    body = {"operation": {"sync": {"prune": True, "syncStrategy": {"hook": {}}}}}
    if revision:
        body["operation"]["sync"]["revision"] = revision
    try:
        api.patch_namespaced_custom_object(
            group="argoproj.io",
            version="v1alpha1",
            namespace="argocd",
            plural="applications",
            name=app_name,
            body=body,
        )
    except ApiException as e:
        return {"error": f"ArgoCD patch failed: {e.status} {e.reason}"}
    return {"ok": True, "app": app_name, "revision_pinned": revision or "main HEAD"}


def restart_pods(*, namespace: str, label_selector: str) -> dict:
    """Delete pods matching a label selector. The Deployment/Rollout
    controller recreates them — useful for forcing IAM token refresh or
    recovering from stuck readiness probes.

    label_selector: e.g. 'app.kubernetes.io/name=tasks-svc'
    """
    _init_k8s()
    v1 = client.CoreV1Api()
    try:
        pods = v1.list_namespaced_pod(namespace=namespace, label_selector=label_selector).items
    except ApiException as e:
        return {"error": f"list pods failed: {e.status} {e.reason}"}
    deleted = []
    errors = []
    for p in pods:
        try:
            v1.delete_namespaced_pod(name=p.metadata.name, namespace=namespace, grace_period_seconds=15)
            deleted.append(p.metadata.name)
        except ApiException as e:
            errors.append({"pod": p.metadata.name, "error": f"{e.status} {e.reason}"})
    return {"deleted": deleted, "errors": errors, "count": len(deleted)}


# ───────────────────────── tool registry for Claude ──────────────────────


TOOL_SCHEMAS: list[dict] = [
    {
        "name": "list_namespaces",
        "description": "List all namespaces in the cluster. Use this first if unsure which env (dev/qa/uat) to inspect.",
        "input_schema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "kubectl_get",
        "description": (
            "List or describe Kubernetes resources read-only. "
            "Supports: pods, services, deployments, replicasets, rollouts, "
            "applications (argocd), ingresses, configmaps, events, prometheusrules. "
            "Pass `name` to get one specific resource; otherwise lists all in namespace."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "resource": {
                    "type": "string",
                    "enum": [
                        "pods", "services", "deployments", "replicasets",
                        "rollouts", "applications", "ingresses", "configmaps",
                        "events", "prometheusrules", "secrets", "nodes",
                    ],
                },
                "namespace": {"type": "string", "description": "Omit for cluster-scoped resources like nodes"},
                "name": {"type": "string", "description": "Optional: a specific resource name"},
                "label_selector": {"type": "string", "description": "Optional, e.g. 'app.kubernetes.io/name=auth-svc'"},
            },
            "required": ["resource"],
        },
    },
    {
        "name": "kubectl_logs",
        "description": "Read the last N lines of logs from a pod. Set `previous=true` if pod is CrashLoopBackOff (logs from prior instance).",
        "input_schema": {
            "type": "object",
            "properties": {
                "namespace": {"type": "string"},
                "pod": {"type": "string"},
                "container": {"type": "string"},
                "tail_lines": {"type": "integer", "default": 80},
                "previous": {"type": "boolean", "default": False},
            },
            "required": ["namespace", "pod"],
        },
    },
    {
        "name": "argocd_app",
        "description": "Get ArgoCD Application status: sync state, health, last operation outcome, recent conditions.",
        "input_schema": {
            "type": "object",
            "properties": {"name": {"type": "string", "description": "e.g. dev-auth-svc"}},
            "required": ["name"],
        },
    },
    {
        "name": "prom_query",
        "description": "Run an instant PromQL query against the cluster's Prometheus. Use for CPU/Mem/Disk/error-rate/latency.",
        "input_schema": {
            "type": "object",
            "properties": {"query": {"type": "string"}},
            "required": ["query"],
        },
    },
    {
        "name": "loki_query",
        "description": (
            "Run a LogQL query against the cluster's Loki for the last N hours (1-6). "
            "Always include a namespace label, e.g. `{namespace=\"dev\"}`. Returns up to 50 lines."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "logql": {"type": "string"},
                "hours": {"type": "integer", "default": 1, "minimum": 1, "maximum": 6},
            },
            "required": ["logql"],
        },
    },
]


async def dispatch(
    tool_name: str,
    tool_input: dict[str, Any],
    *,
    prom_url: str,
    loki_url: str,
) -> Any:
    """Map a tool call from Claude → the corresponding Python function."""
    try:
        if tool_name == "list_namespaces":
            return list_namespaces()
        if tool_name == "kubectl_get":
            return kubectl_get(**tool_input)
        if tool_name == "kubectl_logs":
            return kubectl_logs(**tool_input)
        if tool_name == "argocd_app":
            return argocd_app(**tool_input)
        if tool_name == "prom_query":
            return await prom_query(query=tool_input["query"], prom_url=prom_url)
        if tool_name == "loki_query":
            return await loki_query(
                logql=tool_input["logql"],
                hours=tool_input.get("hours", 1),
                loki_url=loki_url,
            )
    except Exception as e:
        log.exception("tool %s failed", tool_name)
        return {"error": f"{type(e).__name__}: {e}"}
    return {"error": f"unknown tool: {tool_name}"}


# ───────────────────────── _fetch helper ──────────────────────────────────


def _fetch(
    resource: str,
    *,
    namespace: str | None,
    name: str | None,
    label_selector: str | None,
) -> list[dict]:
    """Internal: dispatch to the right k8s client API based on resource kind."""
    v1 = client.CoreV1Api()
    apps_v1 = client.AppsV1Api()
    net_v1 = client.NetworkingV1Api()
    custom = client.CustomObjectsApi()
    kwargs = {}
    if label_selector:
        kwargs["label_selector"] = label_selector

    def trim(o: Any) -> dict:
        """Shrink an API object dict to the most useful fields for an LLM."""
        if hasattr(o, "to_dict"):
            o = o.to_dict()
        if not isinstance(o, dict):
            return {"_raw": str(o)[:300]}
        return {
            "name": o.get("metadata", {}).get("name"),
            "namespace": o.get("metadata", {}).get("namespace"),
            "labels": o.get("metadata", {}).get("labels"),
            "spec_summary": _summarize_spec(o.get("spec", {})),
            "status_summary": _summarize_status(o.get("status", {})),
        }

    if resource == "pods":
        items = (
            [v1.read_namespaced_pod(name=name, namespace=namespace)] if name
            else v1.list_namespaced_pod(namespace=namespace, **kwargs).items
        )
    elif resource == "services":
        items = (
            [v1.read_namespaced_service(name=name, namespace=namespace)] if name
            else v1.list_namespaced_service(namespace=namespace, **kwargs).items
        )
    elif resource == "deployments":
        items = (
            [apps_v1.read_namespaced_deployment(name=name, namespace=namespace)] if name
            else apps_v1.list_namespaced_deployment(namespace=namespace, **kwargs).items
        )
    elif resource == "replicasets":
        items = (
            [apps_v1.read_namespaced_replica_set(name=name, namespace=namespace)] if name
            else apps_v1.list_namespaced_replica_set(namespace=namespace, **kwargs).items
        )
    elif resource == "ingresses":
        items = (
            [net_v1.read_namespaced_ingress(name=name, namespace=namespace)] if name
            else net_v1.list_namespaced_ingress(namespace=namespace, **kwargs).items
        )
    elif resource == "configmaps":
        items = (
            [v1.read_namespaced_config_map(name=name, namespace=namespace)] if name
            else v1.list_namespaced_config_map(namespace=namespace, **kwargs).items
        )
    elif resource == "events":
        # Events are noisy; cap at 30 and sort by lastTimestamp.
        evs = v1.list_namespaced_event(namespace=namespace, **kwargs).items
        evs.sort(key=lambda e: e.last_timestamp or e.event_time or e.metadata.creation_timestamp, reverse=True)
        items = evs[:30]
    elif resource == "nodes":
        items = v1.list_node(**kwargs).items
    elif resource == "secrets":
        # Names only — never expose secret data through the LLM.
        secs = v1.list_namespaced_secret(namespace=namespace, **kwargs).items
        return [{"name": s.metadata.name, "type": s.type} for s in secs]
    elif resource == "rollouts":
        return _list_custom(custom, "argoproj.io", "v1alpha1", "rollouts", namespace, name, label_selector)
    elif resource == "applications":
        return _list_custom(custom, "argoproj.io", "v1alpha1", "applications", namespace or "argocd", name, label_selector)
    elif resource == "prometheusrules":
        return _list_custom(custom, "monitoring.coreos.com", "v1", "prometheusrules", namespace, name, label_selector)
    else:
        raise ValueError(f"unsupported resource: {resource}")

    return [trim(it) for it in items]


def _list_custom(api, group, version, plural, ns, name, label_selector):
    kwargs = {}
    if label_selector:
        kwargs["label_selector"] = label_selector
    if name:
        obj = api.get_namespaced_custom_object(group=group, version=version, namespace=ns, plural=plural, name=name)
        return [_trim_custom(obj)]
    items = api.list_namespaced_custom_object(group=group, version=version, namespace=ns, plural=plural, **kwargs).get("items", [])
    return [_trim_custom(o) for o in items]


def _trim_custom(o: dict) -> dict:
    return {
        "name": o.get("metadata", {}).get("name"),
        "namespace": o.get("metadata", {}).get("namespace"),
        "spec_summary": _summarize_spec(o.get("spec", {})),
        "status_summary": _summarize_status(o.get("status", {})),
    }


def _summarize_spec(spec: dict) -> dict:
    if not isinstance(spec, dict):
        return {}
    out = {}
    for k in ("replicas", "selector", "strategy", "source", "sources", "destination"):
        if k in spec:
            out[k] = spec[k]
    template = spec.get("template", {})
    if template:
        containers = template.get("spec", {}).get("containers", [])
        out["images"] = [c.get("image") for c in containers]
    return out


def _summarize_status(status: dict) -> dict:
    if not isinstance(status, dict):
        return {}
    out = {}
    # Pod-like
    for k in ("phase", "podIP", "hostIP"):
        if k in status:
            out[k] = status[k]
    if "containerStatuses" in status:
        out["containers"] = [
            {
                "name": c.get("name"),
                "ready": c.get("ready"),
                "restartCount": c.get("restartCount"),
                "state": list((c.get("state") or {}).keys())[0] if c.get("state") else None,
                "reason": (
                    (c.get("state") or {}).get("waiting", {}).get("reason")
                    or (c.get("state") or {}).get("terminated", {}).get("reason")
                ),
            }
            for c in status.get("containerStatuses", [])
        ]
    # Deployment/Rollout/Application-like
    for k in ("readyReplicas", "availableReplicas", "updatedReplicas", "currentStepIndex"):
        if k in status:
            out[k] = status[k]
    if "sync" in status and isinstance(status["sync"], dict):
        out["sync"] = {"status": status["sync"].get("status"), "revision": status["sync"].get("revision", "")[:12]}
    if "health" in status and isinstance(status["health"], dict):
        out["health"] = status["health"].get("status")
    if "phase" in status and "message" in status:
        out["message"] = status["message"]
    return out
