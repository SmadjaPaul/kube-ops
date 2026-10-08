#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"

path = ARGV.fetch(0, File.join(__dir__, "company.yaml"))
document = YAML.safe_load(File.read(path), aliases: false)
errors = []

expected_roles = %w[
  portfolio-lead
  principal-architect
  agents-orchestrator
  staff-engineer
  qa-release
  factory-data-lead
  data-platform-engineer
  agent-experience-engineer
]
expected_decisions = %w[REUSE EXTEND COMPOSE ADAPTER NEW_COMPONENT NEW_SERVICE BU_CANDIDATE]

unless document.is_a?(Hash) && document["schema"] == "company/desired-state/v1" && document["kind"] == "CompanyDesiredState"
  errors << "document must be a CompanyDesiredState using company/desired-state/v1"
end

spec = document.fetch("spec", {})
runtime = spec.fetch("runtime", {})
errors << "runtime must be reference-only with heartbeat OFF and no mutation" unless runtime == {
  "provisioningMode" => "reference_only",
  "defaultHeartbeat" => "OFF",
  "environmentDefaults" => { "DEFAULT_HEARTBEAT" => "OFF" },
  "paperclipImport" => "existing_safe_import",
  "runtimeMutation" => "forbidden"
}

roles = spec.fetch("roles", [])
role_ids = roles.map { |role| role["id"] }
errors << "role ids must be unique" unless role_ids.uniq.length == role_ids.length
missing_roles = expected_roles - role_ids
errors << "missing mandatory roles: #{missing_roles.join(', ')}" unless missing_roles.empty?
errors << "every role must have heartbeat OFF and canApproveR2 false" unless roles.all? { |role| role["heartbeat"] == "OFF" && role["canApproveR2"] == false }

capabilities = spec.dig("capabilities") || {}
decisions = capabilities.fetch("decisionVocabulary", [])
errors << "capability decision vocabulary must be exactly #{expected_decisions.join(', ')}" unless decisions == expected_decisions
registry = capabilities.fetch("registry", [])
registry_ids = registry.map { |entry| entry["id"] }
errors << "capability registry contains duplicate ids" unless registry_ids.uniq.length == registry_ids.length
errors << "capability registry must represent every decision class" unless expected_decisions.all? { |decision| registry.any? { |entry| entry["decision"] == decision } }
lookup = capabilities.fetch("lookup", {})
errors << "capability lookup must be required before additions" unless lookup["requiredBeforeAddition"] == true
errors << "capability lookup must default unmatched work to NEW_COMPONENT" unless lookup["noMatchDefault"] == "NEW_COMPONENT"

rights = spec.fetch("decisionRights", [])
right_ids = rights.map { |right| right["id"] }
errors << "decision rights contain duplicate ids" unless right_ids.uniq.length == right_ids.length
errors << "every decision right must require capability lookup" unless rights.all? { |right| right["requiresCapabilityLookup"] == true }

routes = spec.dig("routing", "routes") || []
errors << "default routing heartbeat must be OFF" unless spec.dig("routing", "default", "defaultHeartbeat") == "OFF"
errors << "every route must require capability lookup" unless routes.all? { |route| route["requiredCapabilityLookup"] == true }

policy_ids = (spec.fetch("policies", [])).map { |policy| policy["id"] }
%w[heartbeat-off-by-default capability-lookup-before-addition adr-for-structural-change no-agent-r2-approval reference-only-provisioning].each do |policy_id|
  errors << "missing policy #{policy_id}" unless policy_ids.include?(policy_id)
end

adrs = spec.fetch("architectureDecisions", [])
%w[ADR-001 ADR-002 ADR-003 ADR-004].each do |adr_id|
  errors << "missing accepted architecture decision #{adr_id}" unless adrs.any? { |adr| adr["id"] == adr_id && adr["status"] == "accepted" && !adr["rollback"].to_s.empty? }
end

if errors.empty?
  puts "COMPANY_DESIRED_STATE=PASS"
  puts "COMPANY_MANDATORY_ROLES=#{role_ids.length}"
  puts "COMPANY_CAPABILITY_DECISIONS=#{decisions.join(',')}"
  puts "COMPANY_HEARTBEAT=OFF"
else
  warn errors.map { |error| "ERROR: #{error}" }
  exit 1
end
