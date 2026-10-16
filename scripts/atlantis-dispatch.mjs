const PILOT = Object.freeze({
  repository: "SmadjaPaul/homelab-infra",
  directory: "terraform/atlantis-pilot",
  workspace: "default",
  project: "atlantis-pilot",
  backendStateKey: "atlantis-pilot/terraform.tfstate",
  baseBranch: "main",
  caller: "mastra-atlantis-dispatcher",
});

const SHA256 = /^[a-f0-9]{64}$/;
const COMMIT_SHA = /^[a-f0-9]{40}$/;
const REQUEST_ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$/;

export class DispatchError extends Error {
  constructor(code, message) {
    super(`${code}: ${message}`);
    this.name = "DispatchError";
    this.code = code;
  }
}

function requireString(value, field) {
  if (typeof value !== "string" || value.length === 0) {
    throw new DispatchError("invalid_request", `${field} must be a non-empty string`);
  }
  return value;
}

function requirePilot(request) {
  for (const field of ["repository", "directory", "workspace", "project", "backendStateKey"]) {
    if (request[field] !== PILOT[field]) {
      throw new DispatchError("forbidden_target", `${field} is outside the disposable pilot`);
    }
  }
  if (request.baseBranch !== PILOT.baseBranch) {
    throw new DispatchError("invalid_request", "baseBranch must be main");
  }
}

function requireCommon(request) {
  requirePilot(request);
  if (!COMMIT_SHA.test(requireString(request.headSha, "headSha"))) {
    throw new DispatchError("invalid_request", "headSha must be a lowercase commit SHA");
  }
  if (!Number.isInteger(request.pullRequest) || request.pullRequest < 1) {
    throw new DispatchError("invalid_request", "pullRequest must be a positive integer");
  }
  if (request.caller !== PILOT.caller) {
    throw new DispatchError("unauthorized_caller", "caller is not the dedicated dispatcher identity");
  }
  if (!REQUEST_ID.test(requireString(request.requestId, "requestId"))) {
    throw new DispatchError("invalid_request", "requestId has an invalid format");
  }
  requireString(request.policyRevision, "policyRevision");
  requireString(request.stateLineage, "stateLineage");
  requireString(request.admissionId, "admissionId");
}

function requireCodeAdmission(request) {
  if (!request.codeAdmission || request.codeAdmission.codeApproved !== true ||
      request.codeAdmission.mergeable !== true || request.codeAdmission.undiverged !== true) {
    throw new DispatchError("admission_required", "code admission must be approved, mergeable and undiverged");
  }
  if (request.codeAdmission.evidenceId !== request.admissionId) {
    throw new DispatchError("admission_required", "code admission evidence does not match admissionId");
  }
}

export function validatePlanRequest(request) {
  if (!request || request.action !== "plan") {
    throw new DispatchError("invalid_request", "action must be plan");
  }
  requireCommon(request);
  requireCodeAdmission(request);
  if (!SHA256.test(request.policyRevision)) {
    throw new DispatchError("invalid_request", "policyRevision must be a SHA-256 digest");
  }
  return true;
}

export function validatePlanReceipt(receipt) {
  if (!receipt || receipt.kind !== "atlantis-plan-receipt-v1") {
    throw new DispatchError("invalid_receipt", "plan receipt kind is unsupported");
  }
  for (const field of [
    "id",
    "repository",
    "directory",
    "workspace",
    "project",
    "backendStateKey",
    "stateLineage",
    "policyRevision",
    "admissionId",
    "headSha",
    "planDigest",
    "generatedAt",
    "expiresAt",
  ]) {
    requireString(receipt[field], `receipt.${field}`);
  }
  if (!SHA256.test(receipt.policyRevision) || !SHA256.test(receipt.planDigest)) {
    throw new DispatchError("invalid_receipt", "receipt digests must be SHA-256 values");
  }
  if (!COMMIT_SHA.test(receipt.headSha)) {
    throw new DispatchError("invalid_receipt", "receipt.headSha must be a lowercase commit SHA");
  }
  if (!Number.isInteger(receipt.pullRequest) || receipt.pullRequest < 1) {
    throw new DispatchError("invalid_receipt", "receipt.pullRequest must be a positive integer");
  }
  requirePilot(receipt);
  const expiry = Date.parse(receipt.expiresAt);
  const generated = Date.parse(receipt.generatedAt);
  if (!Number.isFinite(expiry) || !Number.isFinite(generated) || expiry <= generated) {
    throw new DispatchError("invalid_receipt", "receipt timestamps are invalid");
  }
  return true;
}

function matchesReceipt(request, receipt) {
  return [
    "repository",
    "directory",
    "workspace",
    "project",
    "backendStateKey",
    "stateLineage",
    "policyRevision",
    "headSha",
    "pullRequest",
    "admissionId",
  ].every((field) => request[field] === receipt[field]) && request.planDigest === receipt.planDigest;
}

export function buildPlanRequest(request) {
  validatePlanRequest(request);
  return {
    endpoint: "/api/plan",
    body: {
      Repository: request.repository,
      Ref: request.headSha,
      Type: "Github",
      Paths: [{ Directory: request.directory, Workspace: request.workspace }],
      PR: request.pullRequest,
    },
    audit: {
      action: "plan",
      requestId: request.requestId,
      caller: request.caller,
      repository: request.repository,
      headSha: request.headSha,
      directory: request.directory,
      workspace: request.workspace,
      project: request.project,
      backendStateKey: request.backendStateKey,
      policyRevision: request.policyRevision,
      admissionId: request.admissionId,
    },
  };
}

export function buildApplyRequest(request, receipt, { now = new Date() } = {}) {
  if (!request || request.action !== "apply") {
    throw new DispatchError("invalid_request", "action must be apply");
  }
  requireCommon(request);
  requireString(request.planReceiptId, "planReceiptId");
  if (!SHA256.test(request.policyRevision) || !SHA256.test(request.planDigest)) {
    throw new DispatchError("invalid_request", "policyRevision and planDigest must be SHA-256 values");
  }
  validatePlanReceipt(receipt);
  if (receipt.id !== request.planReceiptId) {
    throw new DispatchError("plan_mismatch", "the referenced plan receipt is not the requested receipt");
  }
  if (!matchesReceipt(request, receipt)) {
    throw new DispatchError("plan_mismatch", "SHA, root, workspace, backend lineage, policy or plan digest changed");
  }
  if (Date.parse(receipt.expiresAt) <= now.getTime()) {
    throw new DispatchError("stale_plan", "the plan receipt has expired");
  }
  return {
    endpoint: "/api/apply",
    body: {
      Repository: request.repository,
      Ref: request.headSha,
      Type: "Github",
      Paths: [{ Directory: request.directory, Workspace: request.workspace }],
      PR: request.pullRequest,
    },
    audit: {
      action: "apply",
      requestId: request.requestId,
      caller: request.caller,
      planReceiptId: receipt.id,
      planDigest: receipt.planDigest,
      repository: request.repository,
      headSha: request.headSha,
      directory: request.directory,
      workspace: request.workspace,
      project: request.project,
      backendStateKey: request.backendStateKey,
      stateLineage: request.stateLineage,
      policyRevision: request.policyRevision,
      admissionId: request.admissionId,
    },
  };
}

/**
 * A durable, server-owned replay guard must implement claim(requestId).
 * The dispatcher must claim before sending the API request. A rejected claim
 * is a hard failure: callers must not retry with a new request ID.
 */
export async function authorizeApply(request, receiptStore, replayGuard, options) {
  if (!receiptStore || typeof receiptStore.get !== "function") {
    throw new DispatchError("server_misconfigured", "a server-side receipt store is required");
  }
  if (!replayGuard || typeof replayGuard.claim !== "function") {
    throw new DispatchError("server_misconfigured", "a server-side replay guard is required");
  }
  const receipt = await receiptStore.get(request.planReceiptId);
  const result = buildApplyRequest(request, receipt, options);
  const claimed = await replayGuard.claim(request.requestId, result.audit);
  if (!claimed) {
    throw new DispatchError("duplicate_dispatch", "requestId has already been claimed");
  }
  return result;
}

export { PILOT };
