#!/usr/bin/env node

import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  normalizeApiBase,
  readStoredBoardToken,
} from "./managed-github-preflight.mjs";

const COMPANY_ID_DEFAULT = "0c4afe5a-c044-4b3d-86a2-14a64a063d18";
const API_BASE_DEFAULT = "https://paperclip.smadja.dev";

function methodKeys(githubApp) {
  return Array.isArray(githubApp?.methods)
    ? githubApp.methods
        .map((method) => method?.key)
        .filter((key) => typeof key === "string" && key.trim())
    : [];
}

function managedVisible(githubApp) {
  return methodKeys(githubApp).includes("managed");
}

function enrollmentRequired(status, githubApp) {
  return status?.configured !== true && !managedVisible(githubApp);
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

async function main() {
  const apiBase =
    process.env.PAPERCLIP_API_BASE ||
    process.env.PAPERCLIP_API_URL ||
    API_BASE_DEFAULT;
  const companyId =
    process.env.PAPERCLIP_COMPANY_ID || COMPANY_ID_DEFAULT;

  const auth = readStoredBoardToken(apiBase);
  if (!auth.token) {
    console.log("PAPERCLIP_BOARD_AUTH_STORE_PRESENT=NO");
    console.log("PAPERCLIP_CLOUD_CONNECTOR_STATUS=BLOCKED_NO_STORED_BOARD_CREDENTIAL");
    process.exitCode = 2;
    return;
  }

  console.log("PAPERCLIP_BOARD_AUTH_STORE_PRESENT=YES");

  const [status, gallery] = await Promise.all([
    requestJson(
      apiBase,
      auth.token,
      "/api/tools/oauth/cloud-connector/enrollment",
    ),
    requestJson(
      apiBase,
      auth.token,
      `/api/companies/${encodeURIComponent(companyId)}/tools/gallery`,
    ),
  ]);

  const apps = Array.isArray(gallery?.apps) ? gallery.apps : [];
  const github = apps.find((app) => app?.slug === "github") ?? null;
  const keys = methodKeys(github);
  const visible = managedVisible(github);
  const needsEnrollment = enrollmentRequired(status, github);

  console.log(
    `PAPERCLIP_CLOUD_CONNECTOR_CONFIGURED=${status?.configured === true ? "YES" : "NO"}`,
  );
  console.log(
    `PAPERCLIP_CLOUD_CONNECTOR_STATUS=${String(status?.status ?? "UNKNOWN")}`,
  );
  console.log(
    `PAPERCLIP_CLOUD_CONNECTOR_BROKER=${String(status?.brokerBaseUrl ?? "UNKNOWN")}`,
  );
  console.log(
    `PAPERCLIP_CLOUD_CONNECTOR_ENVIRONMENT=${String(status?.environment ?? "UNKNOWN")}`,
  );
  console.log(
    `PAPERCLIP_CLOUD_CONNECTOR_ORIGINS=${JSON.stringify(
      Array.isArray(status?.origins) ? status.origins : [],
    )}`,
  );
  console.log(
    `PAPERCLIP_CLOUD_CONNECTOR_VERIFICATION_PENDING=${status?.verificationUrl ? "YES" : "NO"}`,
  );

  console.log(
    `PAPERCLIP_GITHUB_VISIBLE_METHODS=${JSON.stringify(keys)}`,
  );
  console.log(
    `PAPERCLIP_GITHUB_MANAGED_METHOD_VISIBLE=${visible ? "YES" : "NO"}`,
  );
  console.log("PAPERCLIP_GITHUB_MANAGED_PROFILE=github.code");
  console.log(
    `PAPERCLIP_CLOUD_CONNECTOR_ENROLLMENT_REQUIRED=${needsEnrollment ? "YES" : "NO"}`,
  );

  if (needsEnrollment) {
    console.log(
      "PAPERCLIP_GITHUB_GATE=SELF_HOSTED_CLOUD_CONNECTOR_ENROLLMENT_REQUIRED",
    );
    process.exitCode = 1;
    return;
  }

  if (!visible) {
    console.log(
      "PAPERCLIP_GITHUB_GATE=GITHUB_CODE_PROFILE_NOT_ADVERTISED",
    );
    process.exitCode = 1;
    return;
  }

  console.log("PAPERCLIP_GITHUB_GATE=READY_FOR_MANAGED_CONNECTION_SETUP");
}

export { enrollmentRequired, managedVisible, methodKeys };

if (
  process.argv[1] &&
  fileURLToPath(import.meta.url) === path.resolve(process.argv[1])
) {
  main().catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
