import test from "node:test";
import assert from "node:assert/strict";
import {
  createPlan,
  managedDescription,
  markerFor,
  markerFromDescription,
  recordsFromSeed,
  validateSeed,
} from "./import-backlog-seed.mjs";

const seed = {
  schema: "paperclip/backlog-seed/v2",
  seedVersion: 2,
  project: { slug: "kube-ops", externalIdNamespace: "smadja/kube-ops" },
  policy: { maxInitialTodoIssues: 10 },
  epics: [{ externalId: "KOPS-E01", type: "EPIC", title: "Governance", status: "backlog", intent: "Gate work." }],
  initialTodoIssues: [{ externalId: "KOPS-I001", type: "HUMAN", title: "Approval", status: "todo", parentExternalId: "KOPS-E01", description: "Human gate." }],
  backlogIssues: [{ externalId: "LLM-010", type: "EXECUTE", title: "Perplexica", status: "backlog", priority: "P1", parentExternalId: "KOPS-E01", acceptanceCriteria: ["Use a scoped key."] }],
};

test("validates stable identities, parents and todo policy", () => {
  assert.equal(recordsFromSeed(seed).length, 3);
  assert.equal(validateSeed(seed).length, 3);
});

test("round-trips the stable marker without treating idempotencyKey as identity", () => {
  const marker = markerFor(seed, seed.epics[0]);
  assert.deepEqual(markerFromDescription(`Governance\n\n${marker}`), {
    namespace: "smadja/kube-ops",
    externalId: "KOPS-E01",
    type: "EPIC",
  });
});

test("preserves non-native semantics in the managed description", () => {
  const description = managedDescription(seed, seed.backlogIssues[0]);
  assert.match(description, /acceptance criteria/);
  assert.match(description, /external-id=LLM-010/);
});

test("empty Paperclip state produces a non-empty create-only plan", async () => {
  const plan = await createPlan({ seed, remote: { projects: [{ id: "project-1", urlKey: "kube-ops" }], issues: [] } });
  assert.deepEqual(plan.counts, { CREATE: 3, UPDATE: 0, UNCHANGED: 0, CONFLICT: 0 });
});

test("matching marker is unchanged and changed content is update", async () => {
  const epic = seed.epics[0];
  const description = managedDescription(seed, epic);
  const unchanged = await createPlan({
    seed,
    remote: { projects: [{ id: "project-1", urlKey: "kube-ops" }], issues: [{ id: "issue-1", projectId: "project-1", title: epic.title, description, status: "backlog" }] },
  });
  assert.equal(unchanged.counts.UNCHANGED, 1);
  const changed = await createPlan({
    seed,
    remote: { projects: [{ id: "project-1", urlKey: "kube-ops" }], issues: [{ id: "issue-1", projectId: "project-1", title: "old", description, status: "backlog" }] },
  });
  assert.equal(changed.counts.UPDATE, 1);
});

test("duplicate stable markers and protected work are conflicts", async () => {
  const description = managedDescription(seed, seed.epics[0]);
  const remote = {
    projects: [{ id: "project-1", urlKey: "kube-ops" }],
    issues: [
      { id: "issue-1", projectId: "project-1", title: "Governance", description, status: "backlog" },
      { id: "issue-2", projectId: "project-1", title: "Governance copy", description, status: "backlog" },
    ],
  };
  const plan = await createPlan({ seed, remote });
  assert.equal(plan.counts.CONFLICT, 1);
});

test("unmarked same-project title is not silently duplicated", async () => {
  const plan = await createPlan({
    seed,
    remote: { projects: [{ id: "project-1", urlKey: "kube-ops" }], issues: [{ id: "issue-1", projectId: "project-1", title: "Governance", description: "legacy", status: "backlog" }] },
  });
  assert.equal(plan.counts.CONFLICT, 1);
});
