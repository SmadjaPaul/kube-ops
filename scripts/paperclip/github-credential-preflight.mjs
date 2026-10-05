#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const COMPANY_ID_DEFAULT = "0c4afe5a-c044-4b3d-86a2-14a64a063d18";
const API_BASE_DEFAULT = "https://paperclip.smadja.dev";

function fail(message) {
  throw new Error(message);
}

function runCliJson(args) {
  const command = process.env.PAPERCLIP_CLI_BIN || "npx";
  const commandArgs = process.env.PAPERCLIP_CLI_BIN
    ? args
    : ["--yes", "paperclipai", ...args];
  const result = spawnSync(command, commandArgs, {
    encoding: "utf8",
    env: Object.fromEntries(
      Object.entries(process.env).filter(
        ([key]) => key !== "NODE_TLS_REJECT_UNAUTHORIZED",
      ),
    ),
  });
  if (result.status !== 0) {
    fail(`Paperclip CLI failed: ${result.stderr.trim()}`);
  }
  try {
    return JSON.parse(result.stdout);
  } catch (error) {
    fail(`Paperclip CLI returned invalid JSON: ${error.message}`);
  }
}

function unwrapList(value, keys) {
  if (Array.isArray(value)) return value;
  for (const key of keys) {
    if (Array.isArray(value?.[key])) return value[key];
  }
  return [];
}

function normalizeName(value) {
  return String(value || "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "");
}

function classifyBinding(binding) {
  if (binding === undefined || binding === null) return "absent";
  if (typeof binding === "string") {
    return binding === "***REDACTED***" ? "inline_redacted" : "inline_value";
  }
  if (typeof binding !== "object" || Array.isArray(binding)) return "unknown";

  const type = String(binding.type || binding.kind || "").toLowerCase();
  if (
    type === "secret_ref" ||
    type === "user_secret_ref" ||
    type === "secret" ||
    type === "secretref" ||
    type === "usersecretref"
  ) {
    return "secret_ref";
  }
  if (
    binding.secretId ||
    binding.secretName ||
    binding.secretRef ||
    binding.userSecretDefinitionId
  ) {
    return "secret_ref";
  }
  if (Object.hasOwn(binding, "value")) return "inline_value";
  return "unknown";
}

function effectiveBinding(agentEnv, projectEnv, key) {
  if (projectEnv && Object.hasOwn(projectEnv, key)) {
    return {
      source: "project",
      classification: classifyBinding(projectEnv[key]),
    };
  }
  if (agentEnv && Object.hasOwn(agentEnv, key)) {
    return {
      source: "agent",
      classification: classifyBinding(agentEnv[key]),
    };
  }
  return { source: "none", classification: "absent" };
}

function secretNames(secret) {
  return [secret?.name, secret?.key]
    .filter((value) => typeof value === "string")
    .map((value) => value.trim());
}

function yesNo(value) {
  return value ? "YES" : "NO";
}

async function main() {
  const companyId = process.env.PAPERCLIP_COMPANY_ID || COMPANY_ID_DEFAULT;
  const apiBase = process.env.PAPERCLIP_API_BASE || API_BASE_DEFAULT;

  const common = ["--api-base", apiBase, "--json"];

  const agents = unwrapList(
    runCliJson(["agent", "list", "--company-id", companyId, ...common]),
    ["agents", "items"],
  );

  const implementation = agents.find((agent) => {
    const candidates = [
      agent?.urlKey,
      agent?.name,
      agent?.title,
      agent?.role,
    ].map(normalizeName);
    return candidates.includes("implementation-engineer");
  });

  if (!implementation?.id) {
    fail("Implementation Engineer not found in Paperclip Company");
  }

  const agent = runCliJson([
    "agent",
    "get",
    implementation.id,
    ...common,
  ]);

  const project = runCliJson([
    "project",
    "get",
    "kube-ops",
    "--company-id",
    companyId,
    ...common,
  ]);

  const secrets = unwrapList(
    runCliJson([
      "secrets",
      "list",
      "--company-id",
      companyId,
      ...common,
    ]),
    ["secrets", "items"],
  );

  const agentEnv =
    agent?.adapterConfig?.env && typeof agent.adapterConfig.env === "object"
      ? agent.adapterConfig.env
      : {};
  const projectEnv =
    project?.env && typeof project.env === "object" ? project.env : {};

  const ghToken = effectiveBinding(agentEnv, projectEnv, "GH_TOKEN");
  const githubToken = effectiveBinding(agentEnv, projectEnv, "GITHUB_TOKEN");

  const ghSafe = ghToken.classification === "secret_ref";
  const githubSafe = githubToken.classification === "secret_ref";
  const pushBindingReady = ghSafe && githubSafe;

  const forbiddenInline =
    ["inline_value", "inline_redacted"].includes(ghToken.classification) ||
    ["inline_value", "inline_redacted"].includes(githubToken.classification);

  const serverCredentialNames = new Set([
    "GITHUB_TOKEN",
    "GH_TOKEN",
    "PAPERCLIP_GITHUB_TOKEN",
  ]);
  const serverCloneCredentialPresent = secrets.some((secret) =>
    secretNames(secret).some((name) => serverCredentialNames.has(name)),
  );

  const githubishSecretPresent = secrets.some((secret) =>
    secretNames(secret).some((name) => /github|gh[_-]?token/i.test(name)),
  );

  console.log(`PAPERCLIP_IMPLEMENTATION_AGENT_ID=${implementation.id}`);
  console.log("PAPERCLIP_IMPLEMENTATION_AGENT=PASS");
  console.log("PAPERCLIP_KUBE_OPS_PROJECT=PASS");
  console.log(`PAPERCLIP_GH_TOKEN_BINDING_SOURCE=${ghToken.source}`);
  console.log(
    `PAPERCLIP_GH_TOKEN_BINDING_CLASS=${ghToken.classification}`,
  );
  console.log(
    `PAPERCLIP_GITHUB_TOKEN_BINDING_SOURCE=${githubToken.source}`,
  );
  console.log(
    `PAPERCLIP_GITHUB_TOKEN_BINDING_CLASS=${githubToken.classification}`,
  );
  console.log(
    `PAPERCLIP_GITHUB_PUSH_CREDENTIAL_BOUND=${yesNo(pushBindingReady)}`,
  );
  console.log(
    `PAPERCLIP_GITHUB_INLINE_CREDENTIAL_PRESENT=${yesNo(forbiddenInline)}`,
  );
  console.log(
    `PAPERCLIP_COMPANY_GITHUB_SECRET_PRESENT=${yesNo(githubishSecretPresent)}`,
  );
  console.log(
    `PAPERCLIP_SERVER_GITHUB_CLONE_CREDENTIAL_PRESENT=${yesNo(
      serverCloneCredentialPresent,
    )}`,
  );
  console.log(
    "PAPERCLIP_MANAGED_GITHUB_CONNECTION=NOT_CHECKED_NONBLOCKING_FOR_FIRST_DOC_SMOKE",
  );

  const docSmokeCredentialReady =
    pushBindingReady &&
    !forbiddenInline;

  console.log(
    `DOC_SMOKE_GITHUB_CREDENTIAL_READY=${yesNo(docSmokeCredentialReady)}`,
  );

  if (!docSmokeCredentialReady) {
    process.exitCode = 1;
  }
}

export {
  classifyBinding,
  effectiveBinding,
  normalizeName,
  secretNames,
  unwrapList,
};

if (
  process.argv[1] &&
  fileURLToPath(import.meta.url) === path.resolve(process.argv[1])
) {
  main().catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
