package main

import rego.v1

allowed_address := "terraform_data.pilot"

deny contains msg if {
  some change in input.resource_changes
  change.address != allowed_address
  change.change.actions != ["no-op"]
  msg := sprintf("resource %q is not admitted by the Atlantis pilot policy", [change.address])
}

deny contains msg if {
  some change in input.resource_changes
  change.address == allowed_address
  change.change.actions != ["create"]
  change.change.actions != ["no-op"]
  msg := sprintf("resource %q has an action outside create/no-op: %v", [change.address, change.change.actions])
}

deny contains msg if {
  some change in input.resource_changes
  change.address == allowed_address
  change.change.actions == ["create"]
  change.change.after.input.marker != "atlantis-plan-only-fixture-v1"
  msg := "terraform_data.pilot marker is not the qualified fixture marker"
}

deny contains msg if {
  some name, output in input.output_changes
  output.change.after_sensitive == true
  msg := sprintf("output %q is sensitive and is not admitted by the pilot policy", [name])
}
