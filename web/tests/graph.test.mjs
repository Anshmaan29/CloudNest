import { test } from "node:test";
import assert from "node:assert/strict";
import { build } from "esbuild";
const code = (
  await build({
    entryPoints: ["web/graph/model.ts"],
    bundle: true,
    write: false,
    format: "esm",
    platform: "node",
  })
).outputFiles[0].text;
const { boundedGraph, filterGraph, layout, FrameBudget, validatedDriveURL } =
  await import(
    "data:text/javascript;base64," + Buffer.from(code).toString("base64")
  );
const fixture = () => ({
  nodes: [
    { id: "a", title: "Decision", project: "one" },
    { id: "b", title: "Reference", project: "one" },
    { id: "c", title: "Other project", project: "two" },
  ],
  edges: [
    { source: "a", target: "b", type: "references" },
    { source: "a", target: "private-hidden", type: "references" },
  ],
  clients: [
    {
      id: "reader",
      projects: ["one"],
      permissions: [],
      expiresAt: "2099-01-01T00:00:00Z",
      status: "configured",
      lastSeen: null,
    },
  ],
  events: [
    {
      id: 1,
      clientId: "reader",
      memoryId: "a",
      action: "retrieved",
      createdAt: "2026-10-31T00:00:00Z",
    },
    {
      id: 2,
      clientId: "unknown",
      memoryId: "a",
      action: "retrieved",
      createdAt: "2026-10-31T00:00:00Z",
    },
    {
      id: 3,
      clientId: "reader",
      memoryId: "private-hidden",
      action: "retrieved",
      createdAt: "2026-10-31T00:00:00Z",
    },
  ],
});
test("visible budget never fabricates edges or retains hidden endpoints/activity", () => {
  const graph = boundedGraph(fixture(), 2);
  assert.deepEqual(
    graph.nodes.map((n) => n.id),
    ["a", "b"],
  );
  assert.deepEqual(graph.edges, [
    { source: "a", target: "b", type: "references" },
  ]);
  assert.deepEqual(
    graph.events.map((e) => e.id),
    [1],
  );
  assert.equal(JSON.stringify(graph).includes("private-hidden"), false);
});
test("duplicate graph identities are rejected and hard budgets cap response work", () => {
  const data = fixture();
  data.nodes.push({ ...data.nodes[0] });
  assert.throws(() => boundedGraph(data, 20));
  const many = {
    nodes: Array.from({ length: 700 }, (_, i) => ({ id: String(i) })),
    edges: [],
    events: [],
    clients: [],
  };
  assert.equal(boundedGraph(many, 10000).nodes.length, 600);
});
test("layout is stable and hub sizes derive exclusively from saved edges", () => {
  const graph = boundedGraph(fixture(), 20);
  const first = layout(graph),
    second = layout(graph);
  assert.deepEqual(first, second);
  assert.deepEqual(
    first.map((n) => n.degree),
    [1, 1, 0],
  );
  assert.ok(first.every((n) => n.position.every(Number.isFinite)));
  assert.equal(graph.edges.length, 1);
});
function scheduler(continuous = false) {
  let serial = 0,
    renders = 0;
  const callbacks = new Map();
  const budget = new FrameBudget(
    (fn) => {
      callbacks.set(++serial, fn);
      return serial;
    },
    (id) => callbacks.delete(id),
    () => renders++,
    continuous,
  );
  return {
    budget,
    callbacks,
    renders: () => renders,
    tick() {
      const item = callbacks.entries().next().value;
      if (item) {
        callbacks.delete(item[0]);
        item[1](100);
      }
    },
  };
}
test("hidden and unfocused rendering is cancelled, including continuous quality", () => {
  const s = scheduler(true);
  s.budget.invalidate();
  assert.equal(s.callbacks.size, 1);
  s.tick();
  assert.equal(s.renders(), 1);
  s.budget.setActive(false);
  assert.equal(s.callbacks.size, 0);
  s.budget.invalidate(30);
  assert.equal(s.callbacks.size, 0);
  s.budget.setActive(true);
  assert.equal(s.callbacks.size, 1);
  s.budget.dispose();
  assert.equal(s.callbacks.size, 0);
  s.budget.invalidate();
  assert.equal(s.callbacks.size, 0);
});
test("on-demand reduced-motion rendering becomes idle after requested frame", () => {
  const s = scheduler(false);
  s.budget.invalidate();
  s.tick();
  assert.equal(s.renders(), 1);
  assert.equal(s.callbacks.size, 0);
  s.budget.invalidate(2);
  s.tick();
  s.tick();
  assert.equal(s.renders(), 3);
  assert.equal(s.callbacks.size, 0);
});
test("actual access pulses can stop without leaving a permanent render loop", () => {
  const s = scheduler(true);
  s.budget.invalidate();
  s.tick();
  s.budget.setContinuous(false);
  s.tick();
  assert.equal(s.callbacks.size, 0);
  s.budget.dispose();
});

test("topic/source/date filters prune edges and access relationships together", () => {
  const data = fixture();
  data.nodes[0] = {
    ...data.nodes[0],
    type: "decision",
    source: "Document A",
    updatedAt: "2026-10-30T00:00:00Z",
  };
  data.nodes[1] = {
    ...data.nodes[1],
    type: "research",
    source: "Document B",
    updatedAt: "2026-10-29T00:00:00Z",
  };
  const graph = boundedGraph(data, 20);
  const result = filterGraph(graph, {
    category: "research",
    source: "document b",
    since: "2026-10-28T00:00:00Z",
  });
  assert.deepEqual(
    result.nodes.map((n) => n.id),
    ["b"],
  );
  assert.equal(result.edges.length, 0);
  assert.equal(result.events.length, 0);
  assert.equal(result.clients.length, 0);
  assert.equal(
    filterGraph(graph, { since: "2026-10-31T00:00:00Z" }).nodes.length,
    0,
  );
});

test("archive access events require real visible archive nodes and authorized clients", () => {
  const data = fixture();
  data.nodes.push({
    id: "archive-one",
    title: "Published dataset",
    project: "one",
    nodeKind: "archive",
    type: "archive",
  });
  data.events.push(
    {
      id: 4,
      clientId: "reader",
      memoryId: "archive-one",
      action: "archive_retrieved",
      createdAt: "2026-10-31T00:00:00Z",
    },
    {
      id: 5,
      clientId: "reader",
      memoryId: "archive-one",
      action: "retrieved",
      createdAt: "2026-10-31T00:00:00Z",
    },
    {
      id: 6,
      clientId: "reader",
      memoryId: "a",
      action: "archive_retrieved",
      createdAt: "2026-10-31T00:00:00Z",
    },
    {
      id: 7,
      clientId: "unknown",
      memoryId: "archive-one",
      action: "archive_retrieved",
      createdAt: "2026-10-31T00:00:00Z",
    },
    {
      id: 8,
      clientId: "reader",
      memoryId: "archive-one",
      action: "owner_archive_published",
      createdAt: "2026-10-31T00:00:00Z",
    },
  );
  const graph = boundedGraph(data, 20);
  assert.deepEqual(
    graph.events.map((event) => event.id),
    [1, 4],
  );
  assert.equal(
    graph.nodes.find((node) => node.id === "archive-one").nodeKind,
    "archive",
  );
  const archiveOnly = filterGraph(graph, { category: "archive" });
  assert.deepEqual(
    archiveOnly.events.map((event) => event.id),
    [4],
  );
  assert.deepEqual(
    archiveOnly.clients.map((client) => client.id),
    ["reader"],
  );
  assert.deepEqual(
    boundedGraph(data, 3).events.map((event) => event.id),
    [1],
  );
});

test("Drive inspector links accept exact supported viewers and reject navigation injection", () => {
  const file = "https://drive.google.com/file/d/archive_123/view";
  const folder = "https://drive.google.com/drive/folders/archive_123";
  assert.equal(validatedDriveURL(file, "archive_123", "file"), file);
  assert.equal(validatedDriveURL(file, "archive_123", "manifest"), file);
  assert.equal(validatedDriveURL(folder, "archive_123", "folder"), folder);
  for (const malicious of [
    "javascript:alert(1)",
    "http://drive.google.com/file/d/archive_123/view",
    "https://drive.google.com.evil.example/file/d/archive_123/view",
    "https://drive.google.com@evil.example/file/d/archive_123/view",
    "https://owner:secret@drive.google.com/file/d/archive_123/view",
    file + "?access_token=secret",
    file + "#unexpected",
    "https://drive.google.com/file/d/different/view",
    folder,
  ])
    assert.equal(validatedDriveURL(malicious, "archive_123", "file"), null);
  assert.equal(validatedDriveURL(file, "../archive_123", "file"), null);
  assert.equal(validatedDriveURL(file, "archive_123", "download"), null);
});
