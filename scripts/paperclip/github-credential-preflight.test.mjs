import test from "node:test";
import assert from "node:assert/strict";

import {
  classifyBinding,
  effectiveBinding,
  normalizeName,
  secretNames,
  unwrapList,
} from "./github-credential-preflight.mjs";

test("normalizes implementation engineer names", () => {
  assert.equal(normalizeName("Implementation Engineer"), "implementation-engineer");
  assert.equal(normalizeName("implementation_engineer"), "implementation-engineer");
});

test("classifies secret references without exposing values", () => {
  assert.equal(
    classifyBinding({ type: "secret_ref", secretId: "secret-1", version: "latest" }),
    "secret_ref",
  );
  assert.equal(
    classifyBinding({ type: "user_secret_ref", key: "github_api_token" }),
    "secret_ref",
  );
  assert.equal(classifyBinding("***REDACTED***"), "inline_redacted");
  assert.equal(classifyBinding("github_pat_should_not_be_here"), "inline_value");
  assert.equal(classifyBinding(undefined), "absent");
});

test("project env overrides agent env", () => {
  const result = effectiveBinding(
    { GH_TOKEN: { type: "secret_ref", secretId: "agent-secret" } },
    { GH_TOKEN: { type: "secret_ref", secretId: "project-secret" } },
    "GH_TOKEN",
  );
  assert.deepEqual(result, { source: "project", classification: "secret_ref" });
});

test("unwraps supported CLI list wrappers", () => {
  assert.deepEqual(unwrapList([{ id: 1 }], ["agents"]), [{ id: 1 }]);
  assert.deepEqual(unwrapList({ agents: [{ id: 2 }] }, ["agents"]), [{ id: 2 }]);
  assert.deepEqual(unwrapList({ items: [{ id: 3 }] }, ["agents", "items"]), [{ id: 3 }]);
});

test("extracts only non-sensitive secret metadata names", () => {
  assert.deepEqual(
    secretNames({ name: "GITHUB_TOKEN", key: "github-token", value: "do-not-read" }),
    ["GITHUB_TOKEN", "github-token"],
  );
});
