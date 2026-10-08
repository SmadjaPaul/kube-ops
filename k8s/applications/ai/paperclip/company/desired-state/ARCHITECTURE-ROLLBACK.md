# Company desired-state architecture and rollback

## Boundary

`desired-state/company.yaml` is the Git-native governance contract for the
Company. It describes organization, roles, capabilities, decision rights,
routing and policies. It is intentionally separate from `.paperclip.yaml`:
the latter remains the existing safe-import package and is not modified to
provision a new fleet of agents.

The manifest is reference-only. `bootstrapAgentRef` may map a mandatory role to
an existing Company contract, while `null` means that the role is modelled but
not provisioned. `defaultHeartbeat: OFF`, `runtimeMutation: forbidden` and
`provisioningMode: reference_only` are explicit invariants.

## Change flow

1. Run the capability lookup and record one of `REUSE`, `EXTEND`, `COMPOSE`,
   `ADAPTER`, `NEW_COMPONENT`, `NEW_SERVICE` or `BU_CANDIDATE`.
2. If the change is structural, add or update an accepted ADR before
   implementation. Structural means a new interface, dependency, service,
   migration or execution/security boundary.
3. Run `ruby desired-state/validate-desired-state.rb` and the repository checks.
4. Review the diff for accidental `.paperclip.yaml` provisioning changes and
   for any heartbeat or runtime mutation.
5. Only a separately approved Paperclip import or runtime change may affect
   live state; this package never does that implicitly.

## Rollback

The safe rollback is a Git revert of the smallest causal desired-state change,
followed by the normal review and delivery process. Reverting a governance
manifest does not delete live agents, issues or workspaces. If a future
runtime/import change was separately approved, its own rollback must be handled
by that change's recorded ADR and Paperclip-supported operation; do not use a
manifest revert as an imperative runtime delete.

For a capability addition, revert the capability evaluation, registry entry,
ADR reference and dependent routing/policy change together. For a routing or
decision-right change, restore the prior manifest version and re-run the
validator before considering the Git state recovered.
