import test from "node:test";
import assert from "node:assert/strict";
import {
  DispatchError,
  authorizeApply,
  buildApplyRequest,
  buildPlanRequest,
  PILOT,
} from "../../scripts/atlantis-dispatch.mjs";

const sha = (character) => character.repeat(64);
const commit = "a".repeat(40);
const policyRevision = sha("b");
const planDigest = sha("c");
const receipt = {
  kind: "atlantis-plan-receipt-v1",
  id: "plan-receipt-20261016-001",
  ...PILOT,
  headSha: commit,
  stateLineage: "oci-lineage-opaque-001",
  policyRevision,
  pullRequest: 137,
  admissionId: "github-admission-137-001",
  planDigest,
  generatedAt: "2026-10-16T10:00:00.000Z",
  expiresAt: "2026-10-16T11:00:00.000Z",
};

function request(action = "apply") {
  return {
    action,
    ...PILOT,
    pullRequest: 137,
    headSha: commit,
    stateLineage: receipt.stateLineage,
    policyRevision,
    admissionId: receipt.admissionId,
    requestId: `${action}-request-001`,
    caller: PILOT.caller,
    ...(action === "plan"
      ? { codeAdmission: { codeApproved: true, mergeable: true, undiverged: true, evidenceId: receipt.admissionId } }
      : {}),
    ...(action === "apply"
      ? { planReceiptId: receipt.id, planDigest }
      : {}),
  };
}

function rejects(fn, code) {
  assert.throws(fn, (error) => error instanceof DispatchError && error.code === code);
}

test("positive plan request is scoped to the pilot and emits no credential", () => {
  const result = buildPlanRequest(request("plan"));
  assert.equal(result.endpoint, "/api/plan");
  assert.deepEqual(result.body.Paths, [{ Directory: PILOT.directory, Workspace: "default" }]);
  assert.equal(result.body.Ref, commit);
  assert.equal("token" in result.body, false);
  assert.equal(JSON.stringify(result).includes("secret"), false);
});

test("positive apply requires an exact, unexpired receipt", async () => {
  const claimed = [];
  const result = await authorizeApply(
    request(),
    { get: async (id) => (id === receipt.id ? receipt : null) },
    { claim: async (id, audit) => { claimed.push({ id, audit }); return true; } },
    { now: new Date("2026-10-16T10:30:00.000Z") },
  );
  assert.equal(result.endpoint, "/api/apply");
  assert.equal(result.body.Ref, commit);
  assert.equal(claimed.length, 1);
  assert.equal(claimed[0].audit.planDigest, planDigest);
});

test("stale SHA is rejected", () => {
  const changed = { ...request(), headSha: "d".repeat(40) };
  rejects(() => buildApplyRequest(changed, receipt, { now: new Date("2026-10-16T10:30:00.000Z") }), "plan_mismatch");
});

test("plan fails closed without code admission", () => {
  const changed = request("plan");
  delete changed.codeAdmission;
  rejects(() => buildPlanRequest(changed), "admission_required");
});

test("non-pilot root is rejected", () => {
  const changed = { ...request(), directory: "terraform/proxmox" };
  rejects(() => buildApplyRequest(changed, receipt), "forbidden_target");
});

test("changed plan digest is rejected", () => {
  const changed = { ...request(), planDigest: sha("d") };
  rejects(() => buildApplyRequest(changed, receipt), "plan_mismatch");
});

test("changed backend lineage is rejected", () => {
  const changed = { ...request(), stateLineage: "different-lineage" };
  rejects(() => buildApplyRequest(changed, receipt), "plan_mismatch");
});

test("duplicate dispatch is rejected by the server-side replay guard", async () => {
  let claimed = false;
  const guard = { claim: async () => { if (claimed) return false; claimed = true; return true; } };
  const store = { get: async () => receipt };
  await authorizeApply(request(), store, guard, { now: new Date("2026-10-16T10:30:00.000Z") });
  await assert.rejects(
    authorizeApply(request(), store, guard, { now: new Date("2026-10-16T10:30:00.000Z") }),
    (error) => error instanceof DispatchError && error.code === "duplicate_dispatch",
  );
});

test("apply fails closed without receipt store or replay guard", async () => {
  await assert.rejects(
    authorizeApply(request(), null, { claim: async () => true }),
    (error) => error instanceof DispatchError && error.code === "server_misconfigured",
  );
  await assert.rejects(
    authorizeApply(request(), { get: async () => receipt }, null),
    (error) => error instanceof DispatchError && error.code === "server_misconfigured",
  );
});
