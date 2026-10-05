import test from "node:test";
import assert from "node:assert/strict";

import {
  connectionIsGithub,
  grantGithub,
  installMatches,
  normalizeApiBase,
  normalizeName,
  repoNamesFromGrant,
} from "./managed-github-preflight.mjs";

test("normalizes API base and implementation labels", () => {
  assert.equal(normalizeApiBase("https://paperclip.example/"), "https://paperclip.example");
  assert.equal(normalizeName("Implementation Engineer"), "implementation-engineer");
});

test("detects GitHub connections by source template or name", () => {
  assert.equal(
    connectionIsGithub({
      name: "Source control",
      config: { sourceTemplateKey: "github" },
    }),
    true,
  );
  assert.equal(connectionIsGithub({ name: "GitHub" }), true);
  assert.equal(connectionIsGithub({ name: "Notion" }), false);
});

test("extracts safe GitHub grant repository metadata", () => {
  const grant = {
    providerTenant: {
      github: {
        login: "paul",
        repositories: [
          { fullName: "SmadjaPaul/kube-ops" },
          { fullName: "SmadjaPaul/homelab-infra" },
        ],
      },
    },
  };
  assert.equal(grantGithub(grant).login, "paul");
  assert.deepEqual(repoNamesFromGrant(grant), [
    "SmadjaPaul/kube-ops",
    "SmadjaPaul/homelab-infra",
  ]);
});

test("matches company or implementation-agent installs only", () => {
  assert.equal(
    installMatches(
      { targetType: "company", targetId: "company-1" },
      "company-1",
      "agent-1",
    ),
    true,
  );
  assert.equal(
    installMatches(
      { targetType: "agent", targetId: "agent-1" },
      "company-1",
      "agent-1",
    ),
    true,
  );
  assert.equal(
    installMatches(
      { targetType: "agent", targetId: "agent-2" },
      "company-1",
      "agent-1",
    ),
    false,
  );
});
