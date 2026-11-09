package main

import rego.v1

allowed_address := "terraform_data.pilot"
allowed_marker := "atlantis-plan-only-fixture-v1"
allowed_pilot_actions := {"create", "update", "no-op"}
allowed_aiostreams_actions := {"create", "update", "no-op"}
allowed_polyfin_address := "polyfin_public_address.canonical"
allowed_polyfin_public_address := "https://tv.smadja.dev"
allowed_polyfin_actions := {"create", "update", "no-op"}

github_settings_address(address) if {
  startswith(address, "github_repository.settings[")
}

aiostreams_family_address(address) if {
  address == "aiostreams_configuration.family"
}

polyfin_public_address(address) if {
  address == allowed_polyfin_address
}

deny contains msg if {
  some change in input.resource_changes
  change.address != allowed_address
  not github_settings_address(change.address)
  not aiostreams_family_address(change.address)
  not polyfin_public_address(change.address)
  change.change.actions != ["no-op"]
  msg := sprintf("resource %q is not admitted by the Atlantis pilot policy", [change.address])
}

deny contains msg if {
  some change in input.resource_changes
  aiostreams_family_address(change.address)
  some action in change.change.actions
  not action in allowed_aiostreams_actions
  msg := sprintf("action %q on %q is not admitted by the AIOStreams policy", [action, change.address])
}

deny contains msg if {
  some change in input.resource_changes
  polyfin_public_address(change.address)
  some action in change.change.actions
  not action in allowed_polyfin_actions
  msg := sprintf("action %q on %q is not admitted by the Polyfin policy", [action, change.address])
}

deny contains msg if {
  some change in input.resource_changes
  polyfin_public_address(change.address)
  change.change.actions == ["create"]
  object.get(change.change.after, "public_address", "") != "https://tv.smadja.dev"
  msg := "Polyfin public address must remain \"https://tv.smadja.dev\""
}

deny contains msg if {
  some change in input.resource_changes
  polyfin_public_address(change.address)
  object.get(change.change, "importing", null) != null
  msg := sprintf("resource %q contains an import and is not admitted", [change.address])
}

deny contains msg if {
  some change in input.resource_changes
  change.address == allowed_address
  some action in change.change.actions
  not action in allowed_pilot_actions
  msg := sprintf("action %q on %q is not admitted by the Atlantis pilot policy", [action, change.address])
}

deny contains msg if {
  some change in input.resource_changes
  change.address == allowed_address
  object.get(change.change, "importing", null) != null
  msg := sprintf("resource %q contains an import and is not admitted", [change.address])
}

deny contains msg if {
  some change in input.resource_changes
  change.address == allowed_address
  change.change.actions == ["create"]
  object.get(object.get(change.change.after, "input", {}), "marker", "") != allowed_marker
  msg := sprintf("terraform_data.pilot marker is not the qualified fixture marker %q", [allowed_marker])
}

deny contains msg if {
  some name, output in input.output_changes
  output.change.after_sensitive == true
  msg := sprintf("output %q is sensitive and is not admitted by the pilot policy", [name])
}
