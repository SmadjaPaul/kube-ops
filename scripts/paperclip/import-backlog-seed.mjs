#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const COMPANY_ID_DEFAULT = "0c4afe5a-c044-4b3d-86a2-14a64a063d18";
const API_BASE_DEFAULT = "https://paperclip.smadja.dev";
const DEFAULT_SEED = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../k8s/applications/ai/paperclip/company/projects/kube-ops/backlog-seed.yaml",
);
const MARKER_START = "<!-- paperclip-seed:v1";
const MARKER_END = "-->";
const VALID_TYPES = new Set(["EPIC", "EXECUTE", "DISCOVER", "DECIDE", "HUMAN"]);
const VALID_STATUSES = new Set(["backlog", "todo", "blocked"]);
const VALID_PRIORITIES = new Set(["P1", "P2", "critical", "high", "medium", "low"]);
const PROTECTED_STATUSES = new Set(["in_progress", "in_review", "done", "cancelled"]);

function parseArgs(argv) {
  const options = {
    apiBase: process.env.PAPERCLIP_API_BASE || API_BASE_DEFAULT,
    companyId: process.env.PAPERCLIP_COMPANY_ID || COMPANY_ID_DEFAULT,
    seed: DEFAULT_SEED,
    apply: false,
    confirmApply: false,
    json: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--apply") options.apply = true;
    else if (arg === "--confirm-apply") options.confirmApply = true;
    else if (arg === "--json") options.json = true;
    else if (arg === "--seed") options.seed = argv[++i];
    else if (arg === "--api-base") options.apiBase = argv[++i];
    else if (arg === "--company-id") options.companyId = argv[++i];
    else if (arg === "--help" || arg === "-h") options.help = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  return options;
}

function usage() {
  return `Usage: import-backlog-seed.mjs [options]

Default mode is read-only dry-run. Apply requires both --apply and
--confirm-apply. CREATE-only plans without blockers/labels can reuse the
authenticated Paperclip CLI session; broader mutations require PAPERCLIP_API_KEY.

Options:
  --seed <path>       Canonical backlog-seed.yaml
  --api-base <url>    Paperclip API base URL
  --company-id <id>   Existing Paperclip company UUID
  --json              Emit machine-readable output
  --apply             Apply a conflict-free plan through the official REST API
  --confirm-apply     Required acknowledgement for --apply
`;
}

function fail(message) {
  throw new Error(message);
}

function loadYaml(filePath) {
  const result = spawnSync("yq", ["-o=json", filePath], { encoding: "utf8" });
  if (result.error?.code === "ENOENT") {
    fail("yq is required to parse the canonical YAML seed");
  }
  if (result.status !== 0) {
    fail(`Unable to parse seed YAML: ${result.stderr.trim()}`);
  }
  try {
    return JSON.parse(result.stdout);
  } catch (error) {
    fail(`yq returned invalid JSON: ${error.message}`);
  }
}

function asArray(value) {
  return Array.isArray(value) ? value : [];
}

function recordsFromSeed(seed) {
  return [
    ...asArray(seed.epics),
    ...asArray(seed.initialTodoIssues),
    ...asArray(seed.backlogIssues),
    ...asArray(seed.blockedIssues),
  ];
}

function validateSeed(seed) {
  const errors = [];
  if (!String(seed.schema || "").startsWith("paperclip/backlog-seed/")) {
    errors.push("schema must start with paperclip/backlog-seed/");
  }
  if (!seed.project?.slug || !seed.project?.externalIdNamespace) {
    errors.push("project.slug and project.externalIdNamespace are required");
  }
  const records = recordsFromSeed(seed);
  const ids = new Set();
  for (const record of records) {
    if (!record.externalId) errors.push("every record requires externalId");
    else if (ids.has(record.externalId)) errors.push(`duplicate externalId: ${record.externalId}`);
    else ids.add(record.externalId);
    if (!VALID_TYPES.has(record.type)) errors.push(`unsupported issue type: ${record.type}`);
    if (!VALID_STATUSES.has(record.status)) errors.push(`unsupported seed status: ${record.status}`);
    if (record.priority && !VALID_PRIORITIES.has(record.priority)) {
      errors.push(`unsupported priority for ${record.externalId}: ${record.priority}`);
    }
    if (record.assigneeAgentId || record.assigneeUserId || record.assignee) {
      errors.push(`assignments are forbidden in seed: ${record.externalId}`);
    }
    if (record.type === "HUMAN" && record.status !== "todo" && record.status !== "backlog") {
      errors.push(`HUMAN record must not be executable: ${record.externalId}`);
    }
  }
  const maxTodo = seed.policy?.maxInitialTodoIssues;
  if (Number.isInteger(maxTodo) && asArray(seed.initialTodoIssues).length > maxTodo) {
    errors.push(`initial TODO count exceeds policy maximum ${maxTodo}`);
  }
  for (const record of records) {
    if (record.parentExternalId && !ids.has(record.parentExternalId)) {
      errors.push(`missing parent ${record.parentExternalId} for ${record.externalId}`);
    }
    const blockers = blockedByExternalIds(record);
    for (const blocker of blockers) {
      if (!ids.has(blocker)) errors.push(`missing blocker ${blocker} for ${record.externalId}`);
    }
  }
  if (errors.length) fail(`Invalid canonical seed:\n- ${errors.join("\n- ")}`);
  return records;
}

function blockedByExternalIds(record) {
  if (Array.isArray(record.blockedByExternalIds)) return record.blockedByExternalIds;
  if (Array.isArray(record.blockedBy)) return record.blockedBy;
  if (record.blockedByExternalId) return [record.blockedByExternalId];
  return [];
}

function paperclipPriority(priority) {
  if (priority === "P1") return "high";
  if (priority === "P2") return "medium";
  return priority;
}

function markerFor(seed, record) {
  return [
    MARKER_START,
    `namespace=${seed.project.externalIdNamespace}`,
    `external-id=${record.externalId}`,
    `type=${record.type}`,
    MARKER_END,
  ].join("\n");
}

function markerFromDescription(description) {
  if (typeof description !== "string") return null;
  const start = description.indexOf(MARKER_START);
  if (start < 0) return null;
  const end = description.indexOf(MARKER_END, start);
  if (end < 0) return null;
  const lines = description.slice(start + MARKER_START.length, end).trim().split("\n");
  const values = {};
  for (const line of lines) {
    const separator = line.indexOf("=");
    if (separator > 0) values[line.slice(0, separator)] = line.slice(separator + 1);
  }
  if (!values.namespace || !values["external-id"] || !values.type) return null;
  return {
    namespace: values.namespace,
    externalId: values["external-id"],
    type: values.type,
  };
}

function managedDescription(seed, record) {
  const base = String(record.description || record.intent || "").trim();
  const sections = [];
  if (record.source) sections.push(`- source: ${record.source}`);
  if (Array.isArray(record.nonGoals) && record.nonGoals.length) {
    sections.push(`- non-goals:\n${record.nonGoals.map((value) => `  - ${value}`).join("\n")}`);
  }
  if (Array.isArray(record.acceptanceCriteria) && record.acceptanceCriteria.length) {
    sections.push(`- acceptance criteria:\n${record.acceptanceCriteria.map((value) => `  - ${value}`).join("\n")}`);
  }
  if (record.evidenceRequired) sections.push(`- evidence required: ${record.evidenceRequired}`);
  if (record.executionBoundary) sections.push(`- execution boundary: ${record.executionBoundary}`);
  if (record.humanRequired === true || record.type === "HUMAN") sections.push("- human required: yes");
  const metadata = sections.length
    ? `\n\n## Canonical backlog metadata (managed)\n${sections.join("\n")}`
    : "";
  return `${base}${metadata}\n\n${markerFor(seed, record)}`.trim();
}

function projectSlug(project) {
  return project.urlKey || project.slug || project.name;
}

function issueProjectId(issue) {
  return issue.projectId || issue.project?.id || null;
}

function issueId(issue) {
  return issue.id || issue.issueId;
}

function unwrapList(value, keys) {
  if (Array.isArray(value)) return value;
  for (const key of keys) if (Array.isArray(value?.[key])) return value[key];
  return [];
}

function runCliJson(args) {
  const command = process.env.PAPERCLIP_CLI_BIN || "npx";
  const commandArgs = process.env.PAPERCLIP_CLI_BIN
    ? args
    : ["--yes", "paperclipai", ...args];
  const result = spawnSync(command, commandArgs, {
    encoding: "utf8",
    env: Object.fromEntries(Object.entries(process.env).filter(([key]) => key !== "NODE_TLS_REJECT_UNAUTHORIZED")),
  });
  if (result.status !== 0) fail(`Paperclip CLI failed: ${result.stderr.trim()}`);
  try {
    return JSON.parse(result.stdout);
  } catch (error) {
    fail(`Paperclip CLI returned invalid JSON: ${error.message}`);
  }
}

function cliCreateArgs(options, payload) {
  const args = [
    "issue", "create",
    "--api-base", options.apiBase,
    "--company-id", options.companyId,
    "--title", payload.title,
    "--description", payload.description,
    "--status", payload.status,
    "--project-id", payload.projectId,
    "--json",
  ];
  if (payload.priority) args.push("--priority", payload.priority);
  if (payload.parentId) args.push("--parent-id", payload.parentId);
  return args;
}

function assertCliCreateOnlyPlanSupported(plan) {
  if (plan.conflicts.length) fail("Refusing to apply a plan containing CONFLICT records");
  if (plan.counts.UPDATE !== 0) {
    fail("CLI-authenticated apply only supports CREATE-only plans; PAPERCLIP_API_KEY is required for UPDATE");
  }
  for (const item of plan.plan.filter((candidate) => candidate.action === "CREATE")) {
    if (item.blockedByExternalIds?.length) {
      fail(`CLI-authenticated apply cannot preserve blockers for ${item.externalId}; PAPERCLIP_API_KEY is required`);
    }
    if (item.payload?.labelIds?.length) {
      fail(`CLI-authenticated apply cannot preserve labels for ${item.externalId}; PAPERCLIP_API_KEY is required`);
    }
  }
}

async function applyCreateOnlyPlanViaCli(plan, options) {
  assertCliCreateOnlyPlanSupported(plan);
  const resolvedIds = new Map(
    plan.plan
      .filter((item) => item.existingIssueId)
      .map((item) => [item.externalId, item.existingIssueId]),
  );
  let remaining = plan.plan.filter((item) => item.action === "CREATE");
  while (remaining.length) {
    const ready = remaining.filter((item) => !item.parentExternalId || resolvedIds.has(item.parentExternalId));
    if (!ready.length) fail("Unable to resolve parent order without inventing hierarchy");
    for (const item of ready) {
      const parentId = item.parentExternalId ? resolvedIds.get(item.parentExternalId) : null;
      const payload = { ...item.payload, ...(parentId ? { parentId } : {}) };
      const response = runCliJson(cliCreateArgs(options, payload));
      const createdId = issueId(response);
      if (!createdId) fail(`Paperclip CLI create did not return an issue id for ${item.externalId}`);
      resolvedIds.set(item.externalId, createdId);
    }
    remaining = remaining.filter((item) => !ready.includes(item));
  }
  return {
    applied: true,
    created: plan.counts.CREATE,
    updated: 0,
    transport: "official-cli",
  };
}

async function apiRequest(apiBase, apiKey, method, route, body) {
  const response = await fetch(`${apiBase.replace(/\/$/, "")}${route}`, {
    method,
    headers: {
      accept: "application/json",
      authorization: `Bearer ${apiKey}`,
      ...(body ? { "content-type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  let payload;
  try {
    payload = text ? JSON.parse(text) : null;
  } catch {
    payload = text;
  }
  if (!response.ok) fail(`Paperclip API ${method} ${route} failed (${response.status}): ${JSON.stringify(payload)}`);
  return payload;
}

async function readRemote(options) {
  if (process.env.PAPERCLIP_API_KEY) {
    const [projects, issues, labels] = await Promise.all([
      apiRequest(options.apiBase, process.env.PAPERCLIP_API_KEY, "GET", `/api/companies/${options.companyId}/projects`),
      apiRequest(options.apiBase, process.env.PAPERCLIP_API_KEY, "GET", `/api/companies/${options.companyId}/issues`),
      apiRequest(options.apiBase, process.env.PAPERCLIP_API_KEY, "GET", `/api/companies/${options.companyId}/labels`),
    ]);
    return {
      projects: unwrapList(projects, ["projects", "items"]),
      issues: unwrapList(issues, ["issues", "items"]),
      labels: unwrapList(labels, ["labels", "items"]),
      transport: "rest",
    };
  }
  const common = ["--api-base", options.apiBase, "--company-id", options.companyId, "--json"];
  const [projects, issues, labels] = await Promise.all([
    runCliJson(["project", "list", ...common]),
    runCliJson(["issue", "list", ...common]),
    runCliJson(["issue", "label:list", ...common]),
  ]);
  return {
    projects: unwrapList(projects, ["projects", "items"]),
    issues: unwrapList(issues, ["issues", "items"]),
    labels: unwrapList(labels, ["labels", "items"]),
    transport: "official-cli",
  };
}

function desiredRecord(seed, record, projectId, parentId = null, blockerIds = [], labelIds = []) {
  const payload = {
    projectId,
    title: record.title,
    description: managedDescription(seed, record),
    status: record.status,
    priority: record.priority ? paperclipPriority(record.priority) : "medium",
    ...(parentId ? { parentId } : {}),
    ...(blockerIds.length ? { blockedByIssueIds: blockerIds } : {}),
    ...(labelIds.length ? { labelIds } : {}),
  };
  return payload;
}

function comparableIssue(issue) {
  return {
    projectId: issueProjectId(issue),
    title: issue.title,
    description: issue.description || "",
    status: issue.status,
    priority: issue.priority || null,
    parentId: issue.parentId || null,
    blockedByIssueIds: [...(issue.blockedByIssueIds || [])].sort(),
    labelIds: [...(issue.labelIds || [])].sort(),
  };
}

function comparablePayload(payload) {
  return {
    projectId: payload.projectId,
    title: payload.title,
    description: payload.description,
    status: payload.status,
    priority: payload.priority || null,
    parentId: payload.parentId || null,
    blockedByIssueIds: [...(payload.blockedByIssueIds || [])].sort(),
    labelIds: [...(payload.labelIds || [])].sort(),
  };
}

function sameJson(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function isAssigned(issue) {
  return Boolean(issue.assigneeAgentId || issue.assigneeUserId || issue.assignee);
}

function buildPlan(seed, records, remote) {
  const projectsBySlug = new Map(remote.projects.map((project) => [projectSlug(project), project]));
  const targetProject = projectsBySlug.get(seed.project.slug);
  if (!targetProject) fail(`Target project does not exist: ${seed.project.slug}`);
  const projectId = targetProject.id;

  const identityMap = new Map();
  const titleMap = new Map();
  for (const issue of remote.issues) {
    const marker = markerFromDescription(issue.description);
    if (marker?.namespace === seed.project.externalIdNamespace) {
      const list = identityMap.get(marker.externalId) || [];
      list.push({ issue, marker });
      identityMap.set(marker.externalId, list);
    }
    if (issueProjectId(issue) === projectId && issue.title) {
      const list = titleMap.get(issue.title) || [];
      list.push(issue);
      titleMap.set(issue.title, list);
    }
  }

  const existingById = new Map();
  for (const [externalId, matches] of identityMap) {
    if (matches.length === 1) existingById.set(externalId, matches[0].issue);
  }
  const plan = [];
  const conflicts = [];
  const resolveLabelIds = (record) => {
    if (Array.isArray(record.labelIds)) return record.labelIds;
    const names = record.labels || record.labelNames;
    if (!Array.isArray(names) || names.length === 0) return [];
    const labelsByName = new Map((remote.labels || []).map((label) => [label.name, label.id]));
    return names.map((name) => labelsByName.get(name) || null);
  };
  for (const record of records) {
    const matches = identityMap.get(record.externalId) || [];
    if (matches.length > 1) {
      const item = { externalId: record.externalId, action: "CONFLICT", reason: "ambiguous stable marker" };
      plan.push(item); conflicts.push(item); continue;
    }
    const existing = matches[0]?.issue;
    if (!existing && (titleMap.get(record.title) || []).length > 0) {
      const item = { externalId: record.externalId, action: "CONFLICT", reason: "same-project title exists without stable marker" };
      plan.push(item); conflicts.push(item); continue;
    }
    const labelIds = resolveLabelIds(record);
    if (labelIds.some((id) => !id)) {
      const item = { externalId: record.externalId, action: "CONFLICT", reason: "requested label does not exist" };
      plan.push(item); conflicts.push(item); continue;
    }
    if (existing) {
      if (issueProjectId(existing) !== projectId) {
        const item = { externalId: record.externalId, action: "CONFLICT", reason: "stable marker belongs to another project" };
        plan.push(item); conflicts.push(item); continue;
      }
      if (isAssigned(existing) || PROTECTED_STATUSES.has(existing.status)) {
        const item = { externalId: record.externalId, action: "CONFLICT", reason: "existing issue is assigned or protected" };
        plan.push(item); conflicts.push(item); continue;
      }
      const parentId = record.parentExternalId ? issueId(existingById.get(record.parentExternalId)) : null;
      const blockerIds = blockedByExternalIds(record).map((id) => issueId(existingById.get(id))).filter(Boolean);
      const payload = desiredRecord(seed, record, projectId, parentId, blockerIds, labelIds);
      const action = sameJson(comparableIssue(existing), comparablePayload(payload)) ? "UNCHANGED" : "UPDATE";
      plan.push({ externalId: record.externalId, action, existingIssueId: issueId(existing), payload });
      continue;
    }
    plan.push({
      externalId: record.externalId,
      action: "CREATE",
      parentExternalId: record.parentExternalId || null,
      blockedByExternalIds: blockedByExternalIds(record),
      payload: desiredRecord(seed, record, projectId, null, [], labelIds),
    });
  }
  const counts = Object.fromEntries(["CREATE", "UPDATE", "UNCHANGED", "CONFLICT"].map((action) => [
    action,
    plan.filter((item) => item.action === action).length,
  ]));
  return { projectId, projectSlug: seed.project.slug, plan, counts, conflicts };
}

async function applyPlan(seed, plan, options) {
  if (!options.confirmApply) fail("--apply requires --confirm-apply");
  if (plan.conflicts.length) fail("Refusing to apply a plan containing CONFLICT records");
  if (!process.env.PAPERCLIP_API_KEY) {
    return applyCreateOnlyPlanViaCli(plan, options);
  }
  const resolvedIds = new Map(
    plan.plan
      .filter((item) => item.existingIssueId)
      .map((item) => [item.externalId, item.existingIssueId]),
  );
  const pending = plan.plan.filter((item) => item.action === "CREATE");
  let remaining = [...pending];
  while (remaining.length) {
    const ready = remaining.filter((item) => !item.parentExternalId || resolvedIds.has(item.parentExternalId));
    if (!ready.length) fail("Unable to resolve parent order without inventing hierarchy");
    for (const item of ready) {
      const parentId = item.parentExternalId ? resolvedIds.get(item.parentExternalId) : null;
      const blockerIds = item.blockedByExternalIds.map((id) => resolvedIds.get(id)).filter(Boolean);
      const payload = { ...item.payload, ...(parentId ? { parentId } : {}), ...(blockerIds.length ? { blockedByIssueIds: blockerIds } : {}) };
      const response = await apiRequest(options.apiBase, process.env.PAPERCLIP_API_KEY, "POST", `/api/companies/${options.companyId}/issues`, {
        ...payload,
        idempotencyKey: `${seed.project.externalIdNamespace}:${item.externalId}`,
      });
      resolvedIds.set(item.externalId, issueId(response));
    }
    remaining = remaining.filter((item) => !ready.includes(item));
  }
  for (const item of plan.plan.filter((candidate) => candidate.action === "UPDATE")) {
    await apiRequest(options.apiBase, process.env.PAPERCLIP_API_KEY, "PATCH", `/api/issues/${item.existingIssueId}`, item.payload);
  }
  return {
    applied: true,
    created: plan.counts.CREATE,
    updated: plan.counts.UPDATE,
  };
}

export async function createPlan({ seed, remote }) {
  const records = validateSeed(seed);
  return buildPlan(seed, records, remote);
}

export {
  assertCliCreateOnlyPlanSupported,
  cliCreateArgs,
  markerFor,
  markerFromDescription,
  managedDescription,
  validateSeed,
  recordsFromSeed,
};

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    console.log(usage());
    return;
  }
  const seed = loadYaml(options.seed);
  const records = validateSeed(seed);
  const remote = await readRemote(options);
  const plan = buildPlan(seed, records, remote);
  if (options.apply) await applyPlan(seed, plan, options);
  const result = {
    paperclipVersion: "2026.1001.0",
    companyId: options.companyId,
    seedSchema: seed.schema,
    seedVersion: seed.seedVersion,
    seedRecords: records.length,
    transport: remote.transport,
    mode: options.apply ? "apply" : "dry-run",
    ...plan,
  };
  if (options.json) console.log(JSON.stringify(result, null, 2));
  else console.log(JSON.stringify(result, null, 2));
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  main().catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
