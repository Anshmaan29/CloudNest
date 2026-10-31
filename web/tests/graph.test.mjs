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
const { boundedGraph, filterGraph, layout, FrameBudget } = await import(
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
