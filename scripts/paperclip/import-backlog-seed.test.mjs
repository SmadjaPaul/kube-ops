import test from "node:test";
import assert from "node:assert/strict";
import {
  assertCliCreateOnlyPlanSupported,
  cliCreateArgs,
  createPlan,
  hydrateUnmarkedTargetProjectIssues,
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

test("normalizes omitted seed priority to Paperclip's medium default", async () => {
  const plan = await createPlan({
    seed,
    remote: { projects: [{ id: "project-1", urlKey: "kube-ops" }], issues: [] },
  });
  const governance = plan.plan.find((item) => item.externalId === "KOPS-E01");
  const perplexica = plan.plan.find((item) => item.externalId === "LLM-010");
  assert.equal(governance?.payload.priority, "medium");
  assert.equal(perplexica?.payload.priority, "high");
});

test("matching marker is unchanged and changed content is update", async () => {
  const epic = seed.epics[0];
  const description = managedDescription(seed, epic);
  const unchanged = await createPlan({
    seed,
    remote: { projects: [{ id: "project-1", urlKey: "kube-ops" }], issues: [{ id: "issue-1", projectId: "project-1", title: epic.title, description, status: "backlog", priority: "medium" }] },
  });
  assert.equal(unchanged.counts.UNCHANGED, 1);
  const changed = await createPlan({
    seed,
    remote: { projects: [{ id: "project-1", urlKey: "kube-ops" }], issues: [{ id: "issue-1", projectId: "project-1", title: "old", description, status: "backlog", priority: "medium" }] },
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


test("CLI-authenticated fallback is create-only and never assigns work", async () => {
  const plan = await createPlan({
    seed,
    remote: { projects: [{ id: "project-1", urlKey: "kube-ops" }], issues: [] },
  });
  assert.doesNotThrow(() => assertCliCreateOnlyPlanSupported(plan));
  const args = cliCreateArgs(
    { apiBase: "https://paperclip.example.test", companyId: "company-1" },
    { ...plan.plan[1].payload, parentId: "issue-parent" },
  );
  assert.ok(args.includes("--parent-id"));
  assert.ok(args.includes("issue-parent"));
  assert.ok(!args.includes("--assignee-agent-id"));
  assert.ok(!args.includes("--api-key"));
});

test("CLI-authenticated fallback fails closed for updates, blockers and labels", async () => {
  const base = await createPlan({
    seed,
    remote: { projects: [{ id: "project-1", urlKey: "kube-ops" }], issues: [] },
  });
  assert.throws(
    () => assertCliCreateOnlyPlanSupported({
      ...base,
      counts: { ...base.counts, CREATE: base.counts.CREATE - 1, UPDATE: 1 },
    }),
    /CREATE-only/,
  );
  assert.throws(
    () => assertCliCreateOnlyPlanSupported({
      ...base,
      plan: [{ ...base.plan[0], blockedByExternalIds: ["KOPS-E01"] }],
      counts: { CREATE: 1, UPDATE: 0, UNCHANGED: 0, CONFLICT: 0 },
    }),
    /cannot preserve blockers/,
  );
  assert.throws(
    () => assertCliCreateOnlyPlanSupported({
      ...base,
      plan: [{ ...base.plan[0], payload: { ...base.plan[0].payload, labelIds: ["label-1"] } }],
      counts: { CREATE: 1, UPDATE: 0, UNCHANGED: 0, CONFLICT: 0 },
    }),
    /cannot preserve labels/,
  );
});


test("same-title unmarked collision reports marker-only repairability", async () => {
  const epic = seed.epics[0];
  const expectedDescription = managedDescription(seed, epic);
  const markerStart = expectedDescription.indexOf("<!-- paperclip-seed:v1");
  const unmarkedDescription = expectedDescription.slice(0, markerStart).trimEnd();
  const plan = await createPlan({
    seed,
    remote: {
      projects: [{ id: "project-1", urlKey: "kube-ops" }],
      issues: [{
        id: "issue-unmarked",
        identifier: "KUBE-99",
        projectId: "project-1",
        title: epic.title,
        description: unmarkedDescription,
        status: "backlog",
        priority: "medium",
      }],
    },
  });
  assert.equal(plan.counts.CONFLICT, 1);
  const conflict = plan.plan.find((item) => item.externalId === "KOPS-E01");
  assert.equal(conflict?.candidates?.[0]?.managedMarkerPresent, false);
  assert.equal(conflict?.candidates?.[0]?.structuralMatch, true);
  assert.equal(conflict?.candidates?.[0]?.descriptionMatchExceptMarker, true);
  assert.equal(conflict?.candidates?.[0]?.markerOnlyRepairCandidate, true);
});


test("hydrates an unmarked list row before stable-marker qualification", async () => {
  const epic = seed.epics[0];
  const fullDescription = managedDescription(seed, epic);
  const markerStart = fullDescription.indexOf("<!-- paperclip-seed:v1");
  const listDescription = fullDescription.slice(0, markerStart).trimEnd();
  const listedIssue = {
    id: "issue-truncated",
    identifier: "SMA-26",
    projectId: "project-1",
    title: epic.title,
    description: listDescription,
    status: "backlog",
    priority: "medium",
  };
  let reads = 0;
  const remote = await hydrateUnmarkedTargetProjectIssues(
    seed,
    {
      projects: [{ id: "project-1", urlKey: "kube-ops" }],
      issues: [listedIssue],
      labels: [],
      transport: "official-cli",
    },
    async (issue) => {
      reads += 1;
      assert.equal(issue.id, "issue-truncated");
      return { ...listedIssue, description: fullDescription };
    },
  );

  assert.equal(reads, 1);
  assert.deepEqual(markerFromDescription(remote.issues[0].description), {
    namespace: "smadja/kube-ops",
    externalId: "KOPS-E01",
    type: "EPIC",
  });

  const plan = await createPlan({ seed, remote });
  const governance = plan.plan.find((item) => item.externalId === "KOPS-E01");
  assert.equal(governance?.action, "UNCHANGED");
  assert.equal(
    plan.conflicts.some((item) => item.externalId === "KOPS-E01"),
    false,
  );
});

test("full issue hydration preserves a genuine unmarked collision", async () => {
  const epic = seed.epics[0];
  const fullDescription = managedDescription(seed, epic);
  const markerStart = fullDescription.indexOf("<!-- paperclip-seed:v1");
  const unmarkedDescription = fullDescription.slice(0, markerStart).trimEnd();
  const listedIssue = {
    id: "issue-really-unmarked",
    identifier: "SMA-27",
    projectId: "project-1",
    title: epic.title,
    description: unmarkedDescription.slice(0, 12),
    status: "backlog",
    priority: "medium",
  };

  const remote = await hydrateUnmarkedTargetProjectIssues(
    seed,
    {
      projects: [{ id: "project-1", urlKey: "kube-ops" }],
      issues: [listedIssue],
      labels: [],
      transport: "official-cli",
    },
    async () => ({
      ...listedIssue,
      description: unmarkedDescription,
    }),
  );

  const plan = await createPlan({ seed, remote });
  const conflict = plan.plan.find((item) => item.externalId === "KOPS-E01");
  assert.equal(conflict?.action, "CONFLICT");
  assert.equal(conflict?.candidates?.[0]?.managedMarkerPresent, false);
  assert.equal(conflict?.candidates?.[0]?.structuralMatch, true);
  assert.equal(conflict?.candidates?.[0]?.descriptionMatchExceptMarker, true);
  assert.equal(conflict?.candidates?.[0]?.markerOnlyRepairCandidate, true);
});
