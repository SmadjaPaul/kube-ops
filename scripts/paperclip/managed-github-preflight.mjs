#!/usr/bin/env node

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const COMPANY_ID_DEFAULT = "0c4afe5a-c044-4b3d-86a2-14a64a063d18";
const API_BASE_DEFAULT = "https://paperclip.smadja.dev";
const TARGET_REPO_DEFAULT = "SmadjaPaul/kube-ops";

function normalizeApiBase(value) {
  return String(value || "").trim().replace(/\/+$/, "");
}

function normalizeName(value) {
  return String(value || "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "");
}

function yesNo(value) {
  return value ? "YES" : "NO";
}

function authStorePath() {
  if (process.env.PAPERCLIP_AUTH_STORE?.trim()) {
    return path.resolve(process.env.PAPERCLIP_AUTH_STORE.trim());
  }
  const home = process.env.PAPERCLIP_HOME?.trim()
    ? path.resolve(process.env.PAPERCLIP_HOME.trim().replace(/^~(?=\/|$)/, os.homedir()))
    : path.join(os.homedir(), ".paperclip");
  return path.join(home, "auth.json");
}

function readStoredBoardToken(apiBase) {
  const file = authStorePath();
  if (!fs.existsSync(file)) return { token: null, path: file };
  const raw = JSON.parse(fs.readFileSync(file, "utf8"));
  const credential = raw?.credentials?.[normalizeApiBase(apiBase)];
  const token =
    credential && typeof credential.token === "string" && credential.token.trim()
      ? credential.token.trim()
      : null;
  return { token, path: file };
}

async function requestJson(apiBase, token, route) {
  const response = await fetch(`${normalizeApiBase(apiBase)}${route}`, {
    headers: {
      authorization: `Bearer ${token}`,
      accept: "application/json",
    },
  });
  const text = await response.text();
  let payload = null;
  try {
    payload = text ? JSON.parse(text) : null;
  } catch {
    payload = null;
  }
  if (!response.ok) {
    const message =
      payload && typeof payload.error === "string"
        ? payload.error
        : `HTTP ${response.status}`;
    throw new Error(`${route}: ${message}`);
  }
  return payload;
}

function connectionIsGithub(connection) {
  const source =
    connection?.config?.sourceTemplateKey ??
    connection?.transportConfig?.sourceTemplateKey ??
    "";
  return (
    normalizeName(source) === "github" ||
    normalizeName(connection?.name).includes("github") ||
    normalizeName(connection?.uid).includes("github")
  );
}

function grantGithub(grant) {
  return grant?.providerTenant?.github ?? null;
}

function repoNamesFromGrant(grant) {
  const github = grantGithub(grant);
  if (!github || !Array.isArray(github.repositories)) return [];
  return github.repositories
    .map((repo) => repo?.fullName)
    .filter((name) => typeof name === "string" && name.trim())
    .map((name) => name.trim());
}

function installMatches(install, companyId, agentId) {
  return (
    (install?.targetType === "company" && install?.targetId === companyId) ||
    (install?.targetType === "agent" && install?.targetId === agentId)
  );
}

async function main() {
  const apiBase =
    process.env.PAPERCLIP_API_BASE ||
    process.env.PAPERCLIP_API_URL ||
    API_BASE_DEFAULT;
  const companyId =
    process.env.PAPERCLIP_COMPANY_ID || COMPANY_ID_DEFAULT;
  const targetRepo =
    process.env.PAPERCLIP_GITHUB_TARGET_REPO || TARGET_REPO_DEFAULT;

  const auth = readStoredBoardToken(apiBase);
  if (!auth.token) {
    console.log("PAPERCLIP_BOARD_AUTH_STORE_PRESENT=NO");
    console.log("PAPERCLIP_MANAGED_GITHUB_CONNECTION=BLOCKED_NO_STORED_BOARD_CREDENTIAL");
    console.log("DOC_SMOKE_MANAGED_GITHUB_READY=NO");
    process.exitCode = 2;
    return;
  }

  console.log("PAPERCLIP_BOARD_AUTH_STORE_PRESENT=YES");

  const agentsPayload = await requestJson(
    apiBase,
    auth.token,
    `/api/companies/${encodeURIComponent(companyId)}/agents`,
  );
  const agents = Array.isArray(agentsPayload)
    ? agentsPayload
    : Array.isArray(agentsPayload?.agents)
      ? agentsPayload.agents
      : [];
  const implementation = agents.find((agent) =>
    [agent?.name, agent?.title, agent?.role, agent?.urlKey]
      .map(normalizeName)
      .includes("implementation-engineer"),
  );
  if (!implementation?.id) {
    throw new Error("Implementation Engineer not found");
  }

  const list = await requestJson(
    apiBase,
    auth.token,
    `/api/companies/${encodeURIComponent(companyId)}/tools/connections`,
  );
  const connections = Array.isArray(list?.connections) ? list.connections : [];
  const githubConnections = connections.filter(connectionIsGithub);

  console.log(`PAPERCLIP_MANAGED_GITHUB_CONNECTION_COUNT=${githubConnections.length}`);

  const candidates = [];
  for (const connection of githubConnections) {
    const [grantsPayload, installsPayload] = await Promise.all([
      requestJson(
        apiBase,
        auth.token,
        `/api/tool-connections/${encodeURIComponent(connection.id)}/grants`,
      ),
      requestJson(
        apiBase,
        auth.token,
        `/api/tool-connections/${encodeURIComponent(connection.id)}/installs`,
      ),
    ]);

    const grants = Array.isArray(grantsPayload?.grants)
      ? grantsPayload.grants
      : [];
    const installs = Array.isArray(installsPayload?.installs)
      ? installsPayload.installs
      : [];

    const activeGithubGrants = grants.filter(
      (grant) =>
        grant?.status === "active" &&
        grantGithub(grant) &&
        grant?.revokedAt == null,
    );

    const repoAccess = activeGithubGrants.some((grant) =>
      repoNamesFromGrant(grant).includes(targetRepo),
    );
    const installedForExecution = installs.some((install) =>
      installMatches(install, companyId, implementation.id),
    );
    const healthy =
      connection?.enabled === true &&
      (connection?.status === undefined || connection.status === "active") &&
      connection?.requiresReauthorization !== true &&
      !["failed", "missing_secret"].includes(String(connection?.healthStatus || ""));

    const logins = [
      ...new Set(
        activeGithubGrants
          .map((grant) => grantGithub(grant)?.login)
          .filter((login) => typeof login === "string" && login.trim()),
      ),
    ];
    const appSlugs = [
      ...new Set(
        activeGithubGrants
          .map((grant) => grantGithub(grant)?.appSlug)
          .filter((slug) => typeof slug === "string" && slug.trim()),
      ),
    ];

    candidates.push({
      id: connection.id,
      name: connection.name,
      status: connection.status ?? "unknown",
      enabled: connection.enabled === true,
      healthStatus: connection.healthStatus ?? "unknown",
      requiresReauthorization: connection.requiresReauthorization === true,
      credentialPolicy: connection.credentialPolicy ?? "unknown",
      activeGrantCount: activeGithubGrants.length,
      repoAccess,
      installedForExecution,
      healthy,
      logins,
      appSlugs,
    });
  }

  const ready = candidates.filter(
    (candidate) =>
      candidate.healthy &&
      candidate.repoAccess &&
      candidate.installedForExecution &&
      candidate.activeGrantCount > 0,
  );

  console.log(
    `PAPERCLIP_MANAGED_GITHUB_CONNECTIONS=${JSON.stringify(
      candidates.map((candidate) => ({
        id: candidate.id,
        name: candidate.name,
        status: candidate.status,
        enabled: candidate.enabled,
        healthStatus: candidate.healthStatus,
        requiresReauthorization: candidate.requiresReauthorization,
        credentialPolicy: candidate.credentialPolicy,
        activeGrantCount: candidate.activeGrantCount,
        targetRepoAccess: candidate.repoAccess,
        installedForExecution: candidate.installedForExecution,
        logins: candidate.logins,
        appSlugs: candidate.appSlugs,
      })),
    )}`,
  );
  console.log(
    `PAPERCLIP_MANAGED_GITHUB_TARGET_REPO_ACCESS=${yesNo(
      candidates.some((candidate) => candidate.repoAccess),
    )}`,
  );
  console.log(
    `PAPERCLIP_MANAGED_GITHUB_INSTALLED_FOR_IMPLEMENTATION=${yesNo(
      candidates.some((candidate) => candidate.installedForExecution),
    )}`,
  );
  console.log(
    `PAPERCLIP_MANAGED_GITHUB_HEALTHY=${yesNo(
      candidates.some((candidate) => candidate.healthy),
    )}`,
  );
  console.log(
    `PAPERCLIP_MANAGED_GITHUB_CONNECTION=${ready.length > 0 ? "READY" : "NOT_READY"}`,
  );
  console.log(
    `DOC_SMOKE_MANAGED_GITHUB_READY=${yesNo(ready.length > 0)}`,
  );

  if (ready.length === 0) process.exitCode = 1;
}

export {
  authStorePath,
  connectionIsGithub,
  grantGithub,
  installMatches,
  normalizeApiBase,
  normalizeName,
  readStoredBoardToken,
  repoNamesFromGrant,
};

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
