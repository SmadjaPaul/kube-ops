package main

import rego.v1

real_repositories := {"factory-platform", "homelab-infra", "kube-ops"}

real_repository(resource) if {
  repository_field(resource, "before", "name", "") in real_repositories
}

real_repository(resource) if {
  repository_field(resource, "after", "name", "") in real_repositories
}

deny contains msg if {
  resource := input.resource_changes[_]
  real_repository(resource)
  resource.change.actions[_] == "delete"
  msg := sprintf("real GitHub repository %q cannot be deleted", [repository_name(resource)])
}

deny contains msg if {
  resource := input.resource_changes[_]
  real_repository(resource)
  resource.change.actions[_] == "replace"
  msg := sprintf("real GitHub repository %q cannot be replaced", [repository_name(resource)])
}

deny contains msg if {
  resource := input.resource_changes[_]
  real_repository(resource)
  repository_field(resource, "before", "archived", false) != true
  repository_field(resource, "after", "archived", false) == true
  msg := sprintf("real GitHub repository %q cannot be archived", [repository_name(resource)])
}

deny contains msg if {
  resource := input.resource_changes[_]
  real_repository(resource)
  repository_field(resource, "before", "name", "") != repository_field(resource, "after", "name", "")
  msg := sprintf("real GitHub repository %q cannot be transferred or renamed", [repository_name(resource)])
}

deny contains msg if {
  resource := input.resource_changes[_]
  real_repository(resource)
  repository_field(resource, "before", "owner", "") != repository_field(resource, "after", "owner", "")
  msg := sprintf("real GitHub repository %q cannot be transferred to another owner", [repository_name(resource)])
}

repository_name(resource) := name if {
  name := repository_field(resource, "before", "name", "")
  name != ""
} else := name if {
  name := repository_field(resource, "after", "name", "")
}

repository_field(resource, side, field, fallback) := value if {
  candidate := object.get(resource.change, side, {})
  candidate != null
  value := object.get(candidate, field, fallback)
} else := fallback if {
  true
}
