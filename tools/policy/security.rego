package main

# OPA / Conftest policies enforcing the K8s security baseline on rendered
# Helm output. Each `deny[msg]` represents a hard-stop in CI.

# ─── helpers ──────────────────────────────────────────────────────────────────

is_workload(kind) {
  kind == "Deployment"
}
is_workload(kind) { kind == "StatefulSet" }
is_workload(kind) { kind == "DaemonSet" }
is_workload(kind) { kind == "Rollout" }                       # Argo Rollouts
is_workload(kind) { kind == "Job" }
is_workload(kind) { kind == "CronJob" }

containers[c] {
  is_workload(input.kind)
  c := input.spec.template.spec.containers[_]
}
containers[c] {
  is_workload(input.kind)
  c := input.spec.template.spec.initContainers[_]
}
# Argo Rollouts spec.template lives at the same path as Deployment, but kept
# explicit for readability.

pod_security_context := input.spec.template.spec.securityContext

# ─── runAsNonRoot (pod-level OR container-level) ──────────────────────────────

deny[msg] {
  is_workload(input.kind)
  not pod_security_context.runAsNonRoot
  c := containers[_]
  not c.securityContext.runAsNonRoot
  msg := sprintf("%s/%s container %s must set runAsNonRoot=true", [input.kind, input.metadata.name, c.name])
}

# ─── readOnlyRootFilesystem ───────────────────────────────────────────────────

deny[msg] {
  is_workload(input.kind)
  c := containers[_]
  not c.securityContext.readOnlyRootFilesystem
  msg := sprintf("%s/%s container %s must set readOnlyRootFilesystem=true", [input.kind, input.metadata.name, c.name])
}

# ─── capabilities drop ALL ────────────────────────────────────────────────────

deny[msg] {
  is_workload(input.kind)
  c := containers[_]
  drops := {x | x := c.securityContext.capabilities.drop[_]}
  not drops["ALL"]
  msg := sprintf("%s/%s container %s must drop ALL capabilities", [input.kind, input.metadata.name, c.name])
}

# ─── allowPrivilegeEscalation false ───────────────────────────────────────────

deny[msg] {
  is_workload(input.kind)
  c := containers[_]
  c.securityContext.allowPrivilegeEscalation == true
  msg := sprintf("%s/%s container %s must set allowPrivilegeEscalation=false", [input.kind, input.metadata.name, c.name])
}

# ─── seccomp RuntimeDefault (pod-level OR container-level) ────────────────────

deny[msg] {
  is_workload(input.kind)
  not pod_security_context.seccompProfile.type
  c := containers[_]
  not c.securityContext.seccompProfile.type
  msg := sprintf("%s/%s container %s must set seccompProfile (RuntimeDefault is the baseline)", [input.kind, input.metadata.name, c.name])
}

# ─── resource requests / limits ───────────────────────────────────────────────

deny[msg] {
  is_workload(input.kind)
  c := containers[_]
  not c.resources.requests.cpu
  msg := sprintf("%s/%s container %s missing resources.requests.cpu", [input.kind, input.metadata.name, c.name])
}

deny[msg] {
  is_workload(input.kind)
  c := containers[_]
  not c.resources.limits.memory
  msg := sprintf("%s/%s container %s missing resources.limits.memory", [input.kind, input.metadata.name, c.name])
}

# ─── liveness + readiness probes ──────────────────────────────────────────────

deny[msg] {
  input.kind == "Deployment"
  c := containers[_]
  not c.livenessProbe
  msg := sprintf("Deployment/%s container %s missing livenessProbe", [input.metadata.name, c.name])
}

deny[msg] {
  input.kind == "Deployment"
  c := containers[_]
  not c.readinessProbe
  msg := sprintf("Deployment/%s container %s missing readinessProbe", [input.metadata.name, c.name])
}

# ─── image must be from approved ECR (no Docker Hub etc.) ─────────────────────

deny[msg] {
  is_workload(input.kind)
  c := containers[_]
  not regex.match(`^[0-9]+\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/usf-devops/`, c.image)
  not regex.match(`^migrate/migrate:`, c.image)               # allow upstream migrate
  msg := sprintf("%s/%s container %s uses non-approved image %s", [input.kind, input.metadata.name, c.name, c.image])
}

# ─── image must NOT be :latest ────────────────────────────────────────────────

deny[msg] {
  is_workload(input.kind)
  c := containers[_]
  endswith(c.image, ":latest")
  msg := sprintf("%s/%s container %s uses :latest tag", [input.kind, input.metadata.name, c.name])
}
