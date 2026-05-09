package main

# Policies for ArgoCD AppProject and Application resources.

deny[msg] {
  input.kind == "AppProject"
  input.spec.sourceRepos[_] == "*"
  msg := sprintf("AppProject/%s must not allow sourceRepos=*", [input.metadata.name])
}

deny[msg] {
  input.kind == "AppProject"
  d := input.spec.destinations[_]
  d.namespace == "*"
  d.server == "*"
  msg := sprintf("AppProject/%s must not allow destinations namespace=* server=*", [input.metadata.name])
}

deny[msg] {
  input.kind == "AppProject"
  w := input.spec.clusterResourceWhitelist[_]
  w.group == "*"
  w.kind == "*"
  msg := sprintf("AppProject/%s must not allow clusterResourceWhitelist group=* kind=*", [input.metadata.name])
}
