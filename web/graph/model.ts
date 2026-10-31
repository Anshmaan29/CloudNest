export interface Node {
  id: string;
  title?: string;
  label?: string;
  project?: string;
  type?: string;
  source?: string;
  updatedAt?: string;
}
export interface Edge {
  source: string;
  target: string;
  type?: string;
}
export interface Client {
  id: string;
  clientName?: string;
  projects: string[];
  permissions: string[];
  expiresAt: string;
  status: string;
  lastSeen: string | null;
  revoked?: boolean;
}
export interface AccessEvent {
  id: number | string;
  clientId: string;
  memoryId: string;
  action: string;
  createdAt: string;
}
export interface Graph {
  nodes: Node[];
  edges: Edge[];
  clients: Client[];
  events: AccessEvent[];
}
export interface PositionedNode extends Node {
  position: [number, number, number];
  degree: number;
  color: number;
}
const palette = [0xb291ff, 0xee82b8, 0x70d5e7, 0xee817b, 0x909fff, 0xc994e8];
export function hash(value: string): number {
  let h = 2166136261;
  for (const c of value) {
    h ^= c.charCodeAt(0);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}
export function boundedGraph(value: unknown, budget: number): Graph {
  if (!value || typeof value !== "object") throw new Error("Invalid graph");
  const data = value as Graph;
  if (
    !Array.isArray(data.nodes) ||
    !Array.isArray(data.edges) ||
    !Array.isArray(data.clients) ||
    !Array.isArray(data.events)
  )
    throw new Error("Invalid graph response");
  const max = Math.max(1, Math.min(600, Math.floor(budget)));
  const ids = new Set<string>();
  const nodes = data.nodes.slice(0, max).map((node) => {
    if (
      !node ||
      typeof node.id !== "string" ||
      node.id.length > 128 ||
      ids.has(node.id)
    )
      throw new Error("Invalid graph identity");
    ids.add(node.id);
    return {
      ...node,
      title: String(node.title ?? node.label ?? node.id).slice(0, 200),
      project: String(node.project ?? "").slice(0, 128),
    };
  });
  const edges = data.edges
    .filter((edge) => edge && ids.has(edge.source) && ids.has(edge.target))
    .slice(0, 4000)
    .map((e) => ({
      source: e.source,
      target: e.target,
      type: String(e.type ?? "related").slice(0, 32),
    }));
  const clientIDs = new Set<string>();
  const clients = data.clients
    .slice(0, 100)
    .filter(
      (c) =>
        c &&
        typeof c.id === "string" &&
        c.id.length <= 64 &&
        !clientIDs.has(c.id) &&
        Array.isArray(c.projects) &&
        Array.isArray(c.permissions),
    )
    .map((c) => {
      clientIDs.add(c.id);
      return c;
    });
  const events = data.events
    .filter(
      (e) =>
        e &&
        e.action === "retrieved" &&
        ids.has(e.memoryId) &&
        clientIDs.has(e.clientId) &&
        Number.isFinite(Date.parse(e.createdAt)),
    )
    .slice(0, 100);
  return { nodes, edges, clients, events };
}
export function filterGraph(
  graph: Graph,
  criteria: { category?: string; source?: string; since?: string },
): Graph {
  const nodes = graph.nodes.filter(
    (n) =>
      (!criteria.category || n.type === criteria.category) &&
      (!criteria.source ||
        (n.source ?? "")
          .toLowerCase()
          .includes(criteria.source.toLowerCase())) &&
      (!criteria.since || (!!n.updatedAt && n.updatedAt >= criteria.since)),
  );
  const ids = new Set(nodes.map((n) => n.id));
  const events = graph.events.filter((e) => ids.has(e.memoryId));
  const clients = new Set(events.map((e) => e.clientId));
  return {
    nodes,
    edges: graph.edges.filter((e) => ids.has(e.source) && ids.has(e.target)),
    events,
    clients: graph.clients.filter((c) => clients.has(c.id)),
  };
}
export function layout(graph: Graph): PositionedNode[] {
  const projects = [...new Set(graph.nodes.map((n) => n.project ?? ""))].sort();
  const degrees = new Map<string, number>();
  for (const edge of graph.edges) {
    degrees.set(edge.source, (degrees.get(edge.source) ?? 0) + 1);
    degrees.set(edge.target, (degrees.get(edge.target) ?? 0) + 1);
  }
  const groups = new Map<string, Node[]>();
  for (const node of graph.nodes) {
    const p = node.project ?? "";
    groups.set(p, [...(groups.get(p) ?? []), node]);
  }
  return graph.nodes.map((node) => {
    const project = node.project ?? "",
      cluster = projects.indexOf(project),
      members = groups.get(project)!,
      index = members.findIndex((n) => n.id === node.id),
      seed = hash(node.id);
    const angle = index * 2.3999632297;
    const radius = 1.4 + Math.sqrt(index) * 1.25;
    const clusterAngle = (cluster * 2 * Math.PI) / Math.max(1, projects.length);
    const spread =
      projects.length === 1 ? 0 : 8 + Math.sqrt(graph.nodes.length) * 0.7;
    const position: [number, number, number] = [
      Math.cos(clusterAngle) * spread + Math.cos(angle) * radius,
      Math.sin(clusterAngle) * spread * 0.68 + Math.sin(angle) * radius,
      ((seed % 1000) / 1000 - 0.5) * (5 + Math.sqrt(members.length) * 0.4),
    ];
    return {
      ...node,
      position,
      degree: degrees.get(node.id) ?? 0,
      color:
        palette[
          hash(project + "\0" + (node.type ?? "memory")) % palette.length
        ],
    };
  });
}
// Scheduling is kept independent of WebGL so visibility and reduced-motion
// guarantees can be exercised without a graphics driver.
export class FrameBudget {
  private active = true;
  private disposed = false;
  private pending = false;
  private remaining = 0;
  constructor(
    private request: (fn: (t: number) => void) => number,
    private cancel: (id: number) => void,
    private render: (time: number) => void,
    private continuous = false,
    private handle: number | null = null,
  ) {}
  invalidate(frames = 1) {
    if (this.disposed) return;
    this.remaining = Math.max(this.remaining, frames);
    this.schedule();
  }
  private schedule() {
    if (
      !this.active ||
      this.pending ||
      this.disposed ||
      (!this.continuous && this.remaining <= 0)
    )
      return;
    this.pending = true;
    this.handle = this.request((time) => {
      this.pending = false;
      this.handle = null;
      if (!this.active || this.disposed) return;
      this.render(time);
      this.remaining = Math.max(0, this.remaining - 1);
      this.schedule();
    });
  }
  setContinuous(continuous: boolean) {
    this.continuous = continuous;
    if (continuous) this.invalidate();
  }
  setActive(active: boolean) {
    this.active = active;
    if (!active && this.handle !== null) {
      this.cancel(this.handle);
      this.handle = null;
      this.pending = false;
    }
    if (active) this.invalidate();
  }
  dispose() {
    this.disposed = true;
    if (this.handle !== null) this.cancel(this.handle);
    this.handle = null;
    this.pending = false;
  }
}
