import test from "node:test";
import assert from "node:assert/strict";

import {
  enrollmentRequired,
  managedVisible,
  methodKeys,
} from "./cloud-connector-preflight.mjs";

test("extracts visible GitHub method keys", () => {
  const app = {
    methods: [
      { key: "managed" },
      { key: "mcp-key" },
    ],
  };
  assert.deepEqual(methodKeys(app), ["managed", "mcp-key"]);
  assert.equal(managedVisible(app), true);
});

test("detects the self-hosted enrollment gate instead of requiring a PAT", () => {
  const filteredGithub = { methods: [{ key: "mcp-key" }] };
  assert.equal(
    enrollmentRequired(
      { configured: false, status: "not_configured" },
      filteredGithub,
    ),
    true,
  );
});

test("does not request enrollment once managed is visible", () => {
  const github = { methods: [{ key: "managed" }, { key: "mcp-key" }] };
  assert.equal(
    enrollmentRequired({ configured: true, status: "active" }, github),
    false,
  );
});
