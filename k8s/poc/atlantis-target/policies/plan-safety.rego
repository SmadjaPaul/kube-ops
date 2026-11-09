package main
import rego.v1

# Conservative baseline; cost/drift/identity must be checked separately.
deny contains msg if {
  some change in object.get(input, "resource_changes", [])
  some action in change.change.actions
  action == "delete"
  msg := sprintf("delete or replace denied: %q", [change.address])
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
  some action in change.change.actions
  not action in {"no-op", "create", "update", "read"}
  msg := sprintf("unrecognized action %q on %q", [action, change.address])
}
