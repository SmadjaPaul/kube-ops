package main

import rego.v1

deny contains msg if {
  some change in object.get(input, "resource_changes", [])
  some action in object.get(change.change, "actions", [])
  action in {"delete", "replace"}
  msg := sprintf("destructive action denied: %q", [change.address])
}

deny contains msg if {
  some change in object.get(input, "resource_changes", [])
  object.get(change.change, "importing", null) != null
  msg := sprintf("import denied: %q", [change.address])
}

deny contains msg if {
  some name, output in object.get(input, "output_changes", {})
  object.get(output.change, "after_sensitive", false)
  msg := sprintf("sensitive output denied: %q", [name])
}

deny contains msg if {
  some change in object.get(input, "resource_changes", [])
  some action in object.get(change.change, "actions", [])
  not action in {"no-op", "create", "update", "read"}
  msg := sprintf("unrecognized action denied: %q on %q", [action, change.address])
}
