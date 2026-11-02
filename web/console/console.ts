import { LocalOwnerConnection } from "./owner-connection";
import { ConversationPanel } from "./conversation-panel";
import { BrowserSession } from "./browser-session";
import { boundedGraph, filterGraph, validatedDriveURL } from "../graph/model";
interface MemoryRecord {
  id: string;
  project: string;
  title: string;
  body: string;
  source: string;
  category: string;
  visibility: "approved" | "private";
  revision: string;
  parentRevision: string | null;
  version: number;
  createdAt: string;
  updatedAt: string;
  expiresAt: string | null;
  relationships: { target: string; type: string }[];
  confidence: string;
  deleted: boolean;
}
interface Proposal {
  id: string;
  clientId: string;
  project: string;
  title: string;
  body: string;
  source: string;
  category: string;
  createdAt: string;
  status: string;
}
interface PublishedArchive {
  id: string;
  project: string;
  visibility: "private" | "approved";
  name: string;
  kind: "file" | "folder";
  bytes: number;
  sha256: string | null;
  driveFileId: string;
  manifestFileId: string;
  driveTarget: "file" | "folder" | "manifest";
  fileCount: number | null;
  checkedAt: string;
  localState: "original" | "recovery" | "removed" | "unknown";
  publishedAt: string;
  driveURL: string;
  manifestURL: string;
}
interface RestoreRequest {
  id: string;
  archiveId: string;
  archiveName?: string | null;
  status: "pending" | "completed" | "dismissed";
  createdAt: string;
  acknowledgedAt: string | null;
}
interface GraphNode {
  id: string;
  nodeKind?: "memory" | "archive";
  title?: string;
  label?: string;
  project?: string;
  category?: string;
  type?: string;
  source?: string;
  updatedAt?: string;
}
interface GraphData {
  nodes: GraphNode[];
  edges: { source: string; target: string; type?: string }[];
  events: unknown[];
  clients: unknown[];
  truncated?: boolean;
}
interface Universe {
  dispose(): void;
  focus(id: string): void;
  setActive(active: boolean): void;
  capturePNG(): Promise<Blob>;
}
const element = <T extends HTMLElement = HTMLElement>(id: string): T => {
  const value = document.getElementById(id);
  if (!value) throw new Error("Missing console control");
  return value as T;
};
const make = <T extends keyof HTMLElementTagNameMap>(
  tag: T,
  text = "",
  className = "",
): HTMLElementTagNameMap[T] => {
  const node = document.createElement(tag);
  node.textContent = text;
  if (className) node.className = className;
  return node;
};
const browserSession = new BrowserSession();
const localOwnerConnection = new LocalOwnerConnection(location.origin);
const unlocked = () => !!credential || browserSession.state.authenticated;
let credential = "",
  busy = false,
  currentView = "memories",
  selected: MemoryRecord | null = null,
  editing: MemoryRecord | null = null,
  nextCursor: string | null = null,
  memories: MemoryRecord[] = [],
  graphData: GraphData | null = null,
  universe: Universe | null = null,
  universeMode: "galaxy" | "orbit" | null = null,
  visibleGraph: GraphData | null = null;
let archives: PublishedArchive[] = [],
  selectedArchive: PublishedArchive | null = null,
  archiveCursor: string | null = null,
  archiveNextCursor: string | null = null,
  archiveHistory: (string | null)[] = [],
  restoreRequests: RestoreRequest[] = [];
const activeRequests = new Set<AbortController>();
let sessionGeneration = 0,
  canonicalReady = false,
  editorOperationId = crypto.randomUUID();
let pendingImportCursor: string | null = null,
  pendingImportInput: unknown[] | null = null;
let reindexCursor: string | null = null,
  deletedCursor: string | null = null;
const authorizationRequest = location.hash.startsWith("#authorize=")
  ? location.hash.slice(11)
  : null;
const titles: Record<string, string> = {
  memories: "Memories",
  inbox: "Review Inbox",
  archives: "Archives",
  handoff: "Continue in Another AI",
  universe: "Memory Universe",
  recovery: "Recovery & export",
  connections: "Connections",
  authorize: "Authorize an AI client",
};
function notice(message: string, error = false) {
  element("notice").textContent = message;
  element("notice").classList.toggle("error", error);
}
async function api<T>(
  path: string,
  method = "GET",
  payload?: unknown,
  idempotencyKey?: string,
): Promise<T> {
  if (!unlocked()) throw new Error("Sign in to the console first.");
  const generation = sessionGeneration,
    controller = new AbortController();
  activeRequests.add(controller);
  const timer = setTimeout(() => controller.abort(), 45_000);
  try {
    const response = await fetch("/api/v1" + path, {
      method,
      headers: {
        ...(credential
          ? { Authorization: "Bearer " + credential }
          : { "X-CloudNest-CSRF": browserSession.state.csrf }),
        Accept: "application/json",
        ...(payload === undefined
          ? {}
          : {
              "Content-Type": "application/json",
              "Idempotency-Key": idempotencyKey ?? crypto.randomUUID(),
            }),
      },
      body: payload === undefined ? undefined : JSON.stringify(payload),
      cache: "no-store",
      redirect: "error",
      credentials: credential ? "omit" : "same-origin",
      signal: controller.signal,
    });
    if (!response.ok) {
      if (response.status === 401) {
        lock();
        notice(
          "Your session expired or owner authorization was rejected. Sign in again with your passkey or advanced owner access.",
          true,
        );
        throw new Error("Authorization rejected.");
      }
      if (response.status === 403 && !credential) {
        lock();
        notice(
          "Your browser security token changed or expired. Reload this page to restore an active session, or sign in again with your passkey.",
          true,
        );
        throw new Error("Browser security token rejected.");
      }
      if (response.status === 409)
        throw new Error(
          "A revision conflict or incomplete write blocked this change. Refresh and inspect Recovery before trying again.",
        );
      if (response.status === 503)
        throw new Error(
          "The canonical Brain is unavailable or not configured. Complete the dedicated server-side Drive setup; local Storage is unaffected.",
        );
      if (response.status === 429)
        throw new Error(
          "The service is limiting requests. Wait before retrying.",
        );
      throw new Error(
        "Request was not completed (HTTP " +
          response.status +
          "). Review your input and connection.",
      );
    }
    const reader = response.body?.getReader();
    if (!reader) throw new Error("Empty service response.");
    const chunks: Uint8Array[] = [];
    let size = 0;
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.length;
      if (size > 2_097_152) {
        await reader.cancel();
        throw new Error(
          "Response exceeded the console budget. Use smaller pages.",
        );
      }
      chunks.push(value);
    }
    const data = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) {
      data.set(chunk, offset);
      offset += chunk.length;
    }
    if (generation !== sessionGeneration) throw new Error("Session changed.");
    browserSession.touch();
    return JSON.parse(
      new TextDecoder("utf-8", { fatal: true }).decode(data),
    ) as T;
  } finally {
    clearTimeout(timer);
    activeRequests.delete(controller);
  }
}
async function run(action: () => Promise<void>) {
  if (busy) return;
  const generation = sessionGeneration;
  busy = true;
  document.body.classList.add("busy");
  element("workspace").setAttribute("aria-busy", "true");
  const buttons = [
    ...document.querySelectorAll<HTMLButtonElement>("button"),
  ].filter((b) => b.id !== "lock");
  const states = buttons.map((b) => b.disabled);
  buttons.forEach((b) => (b.disabled = true));
  try {
    await action();
  } catch (error) {
    if (generation === sessionGeneration)
      notice(
        error instanceof Error
          ? error.message
          : "The operation did not finish. Review Recovery before retrying a write.",
        true,
      );
  } finally {
    if (generation !== sessionGeneration) return;
    buttons.forEach((b, i) => (b.disabled = states[i]));
    busy = false;
    document.body.classList.remove("busy");
    element("workspace").removeAttribute("aria-busy");
    element<HTMLButtonElement>("refresh").disabled = !unlocked();
    element<HTMLButtonElement>("copy-handoff").disabled =
      !element<HTMLTextAreaElement>("handoff-text").value;
    element<HTMLButtonElement>("copy-client-token").disabled =
      !element<HTMLInputElement>("client-token").value;
    updateArchivePagination();
    updateGraphImageButton();
    conversationPanel.syncButtons();
  }
}
function button(label: string, action: () => Promise<void>, className = "") {
  const b = make("button", label, className);
  b.type = "button";
  b.addEventListener("click", () => {
    void run(action);
  });
  return b;
}
function empty(container: HTMLElement, text: string) {
  container.replaceChildren(make("p", text, "empty"));
}
function lock(preservePendingSignOut = false) {
  sessionGeneration++;
  conversationPanel.clear();
  localOwnerConnection.clear();
  element<HTMLInputElement>("token").required = true;
  element<HTMLInputElement>("owner-connection-file").value = "";
  element("owner-connection-status").textContent = "Local owner connection cleared. Choose a connection file again if needed.";
  for (const request of activeRequests) request.abort();
  activeRequests.clear();
  busy = false;
  document.body.classList.remove("busy");
  element("workspace").removeAttribute("aria-busy");
  document
    .querySelectorAll<HTMLButtonElement>("button")
    .forEach((b) => (b.disabled = false));
  canonicalReady = false;
  pendingImportCursor = null;
  pendingImportInput = null;
  credential = "";
  if (!preservePendingSignOut) browserSession.clear();
  element<HTMLFormElement>("passkey-enrollment-form").reset();
  element("passkey-list").replaceChildren();
  selected = null;
  editing = null;
  memories = [];
  archives = [];
  selectedArchive = null;
  archiveCursor = null;
  archiveNextCursor = null;
  archiveHistory = [];
  restoreRequests = [];
  element<HTMLFormElement>("archive-search-form").reset();
  element("archive-page").textContent = "";
  element("restore-queue-count").textContent = "";
  graphData = null;
  visibleGraph = null;
  nextCursor = null;
  disposeUniverse();
  for (const id of [
    "memory-list",
    "detail",
    "proposal-list",
    "graph-list",
    "graph-detail",
    "operations",
    "client-list",
    "audit-list",
    "deleted-list",
    "suggestion-list",
    "consent-details",
    "archive-list",
    "archive-detail",
    "restore-queue",
  ])
    element(id).replaceChildren();
  element<HTMLTextAreaElement>("handoff-text").value = "";
  element<HTMLFormElement>("editor-form").reset();
  element<HTMLDialogElement>("editor").close();
  element<HTMLInputElement>("token").value = "";
  element<HTMLFormElement>("handoff-form").reset();
  element<HTMLInputElement>("query").value = "";
  element<HTMLInputElement>("project-filter").value = "";
  element<HTMLInputElement>("graph-project").value = "";
  element<HTMLInputElement>("import-file").value = "";
  reindexCursor = null;
  deletedCursor = null;
  element<HTMLInputElement>("client-token").value = "";
  element<HTMLFormElement>("client-form").reset();
  element<HTMLInputElement>("import-project").value = "";
  element<HTMLTextAreaElement>("consent-projects").value = "";
  element<HTMLInputElement>("consent-propose").checked = false;
  element<HTMLInputElement>("graph-search").value = "";
  element<HTMLInputElement>("graph-source").value = "";
  element<HTMLInputElement>("graph-date").value = "";
  element<HTMLSelectElement>("graph-category").value = "";
  consentRequest = null;
  element("login").hidden = false;
  element("lock").hidden = true;
  element("connection-status").textContent = "Not connected";
  element("connection-dot").classList.remove("connected");
  document
    .querySelectorAll<HTMLElement>(".view")
    .forEach((x) => (x.hidden = true));
  element("graph-stage").hidden = true;
  element<HTMLButtonElement>("refresh").disabled = true;
  notice(
    "Console locked. The owner credential and visible memory and archive data were cleared from this tab.",
  );
}
async function view(name: string) {
  currentView = name;
  disposeUniverse();
  element("graph-stage").hidden = true;
  element("page-title").textContent = titles[name] ?? "Memories";
  document.querySelectorAll<HTMLButtonElement>("nav button").forEach((b) => {
    if (b.dataset.view === name) b.setAttribute("aria-current", "page");
    else b.removeAttribute("aria-current");
  });
  document
    .querySelectorAll<HTMLElement>(".view")
    .forEach((x) => (x.hidden = !unlocked() || x.id !== name));
  if (!unlocked()) return;
  if (name === "memories") await loadMemories();
  else if (name === "inbox") await loadInbox();
  else if (name === "archives") {
    await loadArchives();
    await loadRestoreQueue();
  } else if (name === "recovery") { await loadOperations(); await conversationPanel.loadHistory(); }
  else if (name === "universe") await loadGraph();
  else if (name === "connections") await loadConnections();
  else if (name === "authorize") await loadConsent();
}
async function loadMemories(append = false) {
  const q = new URLSearchParams({
    query: element<HTMLInputElement>("query").value,
    project: element<HTMLInputElement>("project-filter").value,
    limit: "20",
  });
  if (append && nextCursor) q.set("cursor", nextCursor);
  const result = await api<{ memories: MemoryRecord[]; cursor: string | null }>(
    "/memories?" + q,
  );
  if (!Array.isArray(result.memories))
    throw new Error("Invalid memory response.");
  memories = append
    ? [...memories, ...result.memories].slice(-300)
    : result.memories;
  nextCursor = result.cursor;
  const list = element("memory-list");
  list.replaceChildren();
  if (!memories.length)
    empty(
      list,
      "No matching memories. Add a user-confirmed note or review an AI proposal.",
    );
  for (const memory of memories) {
    const card = button("", async () => showMemory(memory), "memory-card");
    card.dataset.memoryId = memory.id;
    card.setAttribute("aria-pressed", String(selected?.id === memory.id));
    card.append(
      make("strong", memory.title),
      make(
        "small",
        memory.project +
          " · " +
          memory.category +
          " · " +
          (memory.visibility === "private" ? "Private" : "Approved"),
      ),
      make("small", memory.body.slice(0, 160)),
    );
    list.append(card);
  }
  element("more").hidden = !nextCursor;
  if (selected) {
    const current = memories.find((m) => m.id === selected?.id);
    if (current) await showMemory(current);
    else {
      selected = null;
      empty(
        element("detail"),
        "Select a matching memory to inspect its current revision.",
      );
    }
  }
  notice(
    memories.length +
      " memories loaded. Private entries are available only to the owner.",
  );
}
function updateArchivePagination() {
  element<HTMLButtonElement>("archive-previous").disabled =
    !unlocked() || archiveHistory.length === 0;
  element<HTMLButtonElement>("archive-next").disabled =
    !unlocked() || !archiveNextCursor;
}
function archiveBytes(value: number): string {
  if (!Number.isSafeInteger(value) || value < 0) return "Size unavailable";
  const units = ["B", "KB", "MB", "GB", "TB", "PB"];
  let index = 0;
  while (value >= 1000 && index < units.length - 1) {
    value /= 1000;
    index++;
  }
  return (
    new Intl.NumberFormat(undefined, { maximumFractionDigits: 1 }).format(
      value,
    ) +
    " " +
    units[index]
  );
}
async function loadArchives(
  cursor: string | null = archiveCursor,
  history: (string | null)[] = archiveHistory,
) {
  const query = new URLSearchParams({
    query: element<HTMLInputElement>("archive-query").value,
    project: element<HTMLInputElement>("archive-project").value,
    limit: "20",
  });
  if (cursor) query.set("cursor", cursor);
  const result = await api<{
    archives: PublishedArchive[];
    cursor: string | null;
  }>("/archives?" + query);
  if (
    !Array.isArray(result.archives) ||
    result.archives.length > 20 ||
    (result.cursor !== null && typeof result.cursor !== "string")
  ) {
    throw new Error("Invalid archive catalog response.");
  }
  archives = result.archives;
  archiveCursor = cursor;
  archiveHistory = [...history];
  archiveNextCursor = result.cursor;
  const list = element("archive-list");
  list.replaceChildren();
  for (const archive of archives) {
    const card = button(
      "",
      async () => showArchive(archive.id),
      "memory-card archive-card",
    );
    card.dataset.archiveId = archive.id;
    card.setAttribute(
      "aria-pressed",
      String(selectedArchive?.id === archive.id),
    );
    card.append(
      make("strong", archive.name),
      make(
        "small",
        archive.project +
          " · " +
          archive.kind +
          " · " +
          archiveBytes(archive.bytes),
      ),
      make(
        "small",
        archive.visibility === "private"
          ? "Private · owner only"
          : "Approved · authorized project clients",
      ),
    );
    list.append(card);
  }
  if (!archives.length)
    empty(
      list,
      "No matching published archives. Publish selected, freshly verified metadata from CloudNest on your Mac; local paths and file contents stay out of this catalog.",
    );
  element("archive-page").textContent =
    "Page " +
    (archiveHistory.length + 1) +
    " · " +
    archives.length +
    " published archives";
  updateArchivePagination();
  if (!selectedArchive)
    empty(
      element("archive-detail"),
      "Select an archive to inspect its last Mac-reported state and supported Drive links.",
    );
  if (selectedArchive) {
    const current = archives.find(
      (archive) => archive.id === selectedArchive?.id,
    );
    if (current) await showArchive(current.id);
    else {
      selectedArchive = null;
      empty(
        element("archive-detail"),
        "Select an archive to inspect its last Mac-reported state and supported Drive links.",
      );
    }
  }
  notice(
    "Published archive metadata loaded. Health and local state reflect the last Mac report, not a live Drive check.",
  );
}
async function showArchive(id: string) {
  const result = await api<{ archive: PublishedArchive }>(
    "/archives/" + encodeURIComponent(id),
  );
  selectedArchive = result.archive;
  renderArchiveDetail(result.archive, element("archive-detail"));
  document
    .querySelectorAll<HTMLElement>(".archive-card")
    .forEach((card) =>
      card.setAttribute(
        "aria-pressed",
        String(card.dataset.archiveId === result.archive.id),
      ),
    );
}
function renderArchiveDetail(archive: PublishedArchive, detail: HTMLElement) {
  const states = {
    original: "Original retained on Mac",
    recovery: "In local CloudNest recovery",
    removed: "Managed local copy removed",
    unknown: "Local state unknown",
  };
  detail.replaceChildren(
    make("h2", archive.name),
    make(
      "p",
      archive.project +
        " · " +
        archive.kind +
        " · " +
        archiveBytes(archive.bytes),
      "meta",
    ),
    make("p", "Visibility: " + archive.visibility, "meta"),
    make("p", states[archive.localState] ?? states.unknown, "meta"),
    make("p", "Last Mac integrity check: " + archive.checkedAt, "meta"),
    make("p", "Metadata published: " + archive.publishedAt, "meta"),
  );
  if (archive.fileCount !== null)
    detail.append(
      make("p", "Files in folder manifest: " + archive.fileCount, "meta"),
    );
  if (archive.sha256)
    detail.append(
      make("p", "SHA-256: " + archive.sha256, "meta archive-checksum"),
    );
  detail.append(
    make(
      "p",
      "This is published metadata. Opening a Drive link uses your Google account permissions; CloudNest does not proxy file contents or change sharing.",
      "fine",
    ),
  );
  const actions = make("div", "", "actions archive-links");
  const addDriveLink = (
    label: string,
    value: string,
    id: string,
    target: string,
  ) => {
    const href = validatedDriveURL(value, id, target);
    if (!href) return false;
    const link = make("a", label, "action-link");
    link.href = href;
    link.target = "_blank";
    link.rel = "noopener noreferrer";
    link.referrerPolicy = "no-referrer";
    actions.append(link);
    return true;
  };
  addDriveLink(
    archive.driveTarget === "manifest"
      ? "Open folder manifest in Drive"
      : archive.driveTarget === "folder"
        ? "Open folder in Drive"
        : "Open file in Drive",
    archive.driveURL,
    archive.driveFileId,
    archive.driveTarget,
  );
  if (
    archive.driveFileId !== archive.manifestFileId ||
    archive.driveTarget !== "manifest"
  ) {
    addDriveLink(
      "Open recovery manifest in Drive",
      archive.manifestURL,
      archive.manifestFileId,
      "manifest",
    );
  }
  if (!actions.children.length)
    actions.append(
      make(
        "p",
        "Drive links could not be validated. Inspect this archive on your Mac.",
        "fine",
      ),
    );
  actions.append(
    button("Queue restore on Mac…", async () => {
      if (
        !confirm(
          "Queue a restore request for “" +
            archive.name +
            "”? CloudNest on your Mac must review the request and ask you to choose a local destination. Nothing is downloaded or overwritten by this console.",
        )
      )
        return;
      await api("/restore-requests", "POST", { archiveId: archive.id });
      await loadRestoreQueue();
      notice(
        "Restore request queued. Open CloudNest on your Mac to review it, choose a destination, and verify the restored data.",
      );
    }),
  );
  detail.append(actions);
}
async function loadRestoreQueue() {
  const result = await api<{ requests: RestoreRequest[] }>("/restore-requests");
  if (!Array.isArray(result.requests) || result.requests.length > 100)
    throw new Error("Invalid restore queue response.");
  restoreRequests = result.requests;
  const queue = element("restore-queue");
  queue.replaceChildren();
  for (const request of restoreRequests) {
    const row = make("article", "", "history-row restore-request");
    const description = make("div", "", "stack");
    description.append(
      make(
        "h3",
        request.archiveName ??
          archives.find((archive) => archive.id === request.archiveId)?.name ??
          "Archive " + request.archiveId,
      ),
      make("p", "Queued " + request.createdAt, "meta"),
      make("p", "Pending Mac review · destination chosen locally", "meta"),
    );
    row.append(
      description,
      button("Dismiss request…", async () => {
        if (
          !confirm(
            "Dismiss this queued restore request? Drive and local files are unchanged. A restore already started on a Mac is not cancelled.",
          )
        )
          return;
        await api(
          "/restore-requests/" + encodeURIComponent(request.id) + "/ack",
          "POST",
          { status: "dismissed" },
        );
        await loadRestoreQueue();
        notice(
          "Restore request dismissed. No archived or local files were deleted.",
        );
      }),
    );
    queue.append(row);
  }
  if (!restoreRequests.length)
    empty(
      queue,
      "No pending restore requests. Queue one from an archive’s details when you want to restore it on your Mac.",
    );
  element("restore-queue-count").textContent =
    restoreRequests.length + " pending";
}
async function showMemory(memory: MemoryRecord) {
  selected = memory;
  const detail = element("detail");
  detail.replaceChildren(
    make("h2", memory.title),
    make("p", memory.body, "body"),
    make(
      "p",
      "Project: " +
        memory.project +
        " · " +
        memory.category +
        " · " +
        memory.visibility,
      "meta",
    ),
    make("p", "Source: " + memory.source, "meta"),
    make(
      "p",
      "Revision " +
        memory.version +
        " · " +
        memory.updatedAt +
        " · " +
        memory.confidence,
      "meta",
    ),
  );
  if (memory.relationships?.length)
    detail.append(
      make(
        "p",
        "References: " +
          memory.relationships.map((r) => r.type + " → " + r.target).join(", "),
        "meta",
      ),
    );
  const actions = make("div", "", "actions");
  actions.append(
    button("Edit", async () => openEditor(memory)),
    button("History", async () => showHistory(memory)),
    button("Download Markdown", async () => downloadMarkdown(memory)),
    button(
      "Delete…",
      async () => {
        if (
          !confirm(
            "Delete “" +
              memory.title +
              "”? A canonical tombstone will hide it from search and AI retrieval. History remains available for explicit recovery.",
          )
        )
          return;
        await api("/memories/" + encodeURIComponent(memory.id), "DELETE", {
          expectedRevision: memory.revision,
        });
        selected = null;
        detail.replaceChildren(
          make("p", "Deleted. A canonical tombstone records this change."),
        );
        await loadMemories();
      },
      "danger",
    ),
  );
  detail.append(actions);
  document
    .querySelectorAll<HTMLElement>(".memory-card")
    .forEach((x) =>
      x.setAttribute("aria-pressed", String(x.dataset.memoryId === memory.id)),
    );
}
async function showHistory(
  memory: MemoryRecord,
  beforeVersion: number | null = null,
  target = element("detail"),
) {
  const result = await api<{
    revisions: MemoryRecord[];
    cursor: number | null;
  }>(
    "/memories/" +
      encodeURIComponent(memory.id) +
      "/history" +
      (beforeVersion ? "?beforeVersion=" + beforeVersion : ""),
  );
  const section = make("section", "", "stack");
  section.append(
    make("h3", beforeVersion ? "Earlier revisions" : "Revision history"),
  );
  for (const record of result.revisions) {
    const row = make("div", "", "stack history-row");
    row.append(
      make(
        "p",
        "Version " +
          record.version +
          " · " +
          record.updatedAt +
          (record.deleted ? " · deleted" : ""),
        "meta",
      ),
      make("p", record.body, "proposal-body"),
      make(
        "p",
        "Project: " +
          record.project +
          " · Visibility: " +
          record.visibility +
          " · Category: " +
          record.category,
        "meta",
      ),
      make(
        "p",
        "Source: " +
          record.source +
          " · Expiry: " +
          (record.expiresAt ?? "none"),
        "meta",
      ),
    );
    if (record.revision !== memory.revision && !record.deleted)
      row.append(
        button("Restore this revision…", async () => {
          if (
            !confirm(
              "Restore version " +
                record.version +
                " in project “" +
                record.project +
                "” with " +
                record.visibility +
                " visibility? " +
                (record.visibility === "approved"
                  ? "Authorized AI clients in that project can read this restored content. "
                  : "Only the owner can read it. ") +
                "Current history will be retained.",
            )
          )
            return;
          const saved = await api<{ memory: MemoryRecord }>(
            "/memories/" + encodeURIComponent(memory.id) + "/restore",
            "POST",
            { expectedRevision: memory.revision, revision: record.revision },
          );
          await view("memories");
          await showMemory(saved.memory);
          notice("A new canonical revision restored this memory.");
        }),
      );
    section.append(row);
  }
  if (result.cursor) {
    const more = button("Load earlier revisions", async () => {
      more.remove();
      await showHistory(memory, result.cursor, target);
    });
    section.append(more);
  }
  target.append(section);
}
async function downloadMarkdown(memory: MemoryRecord) {
  const { body, ...metadata } = memory;
  const blob = new Blob(
    [
      "<!-- CloudNest canonical memory v1 -->\n```json\n" +
        JSON.stringify(metadata, null, 2) +
        "\n```\n\n" +
        body,
    ],
    { type: "text/markdown;charset=utf-8" },
  );
  download(blob, "cloudnest-memory-" + memory.id + ".md");
}
function download(blob: Blob, name: string) {
  const url = URL.createObjectURL(blob),
    link = make("a");
  link.href = url;
  link.download = name;
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function openEditor(memory: MemoryRecord | null) {
  editing = memory;
  editorOperationId = crypto.randomUUID();
  const form = element<HTMLFormElement>("editor-form");
  form.reset();
  element("editor-title").textContent = memory ? "Edit memory" : "New memory";
  if (memory)
    for (const field of [
      "title",
      "project",
      "category",
      "body",
      "source",
      "visibility",
    ] as const) {
      const input = form.elements.namedItem(field) as
        | HTMLInputElement
        | HTMLSelectElement
        | HTMLTextAreaElement
        | null;
      if (input) input.value = memory[field];
    }
  const relations = form.elements.namedItem(
    "relationships",
  ) as HTMLTextAreaElement;
  relations.value =
    memory?.relationships.map((r) => r.type + ": " + r.target).join("\n") ?? "";
  const expiry = form.elements.namedItem("expiresAt") as HTMLInputElement;
  if (memory?.expiresAt) {
    const date = new Date(memory.expiresAt);
    expiry.value = new Date(date.getTime() - date.getTimezoneOffset() * 60000)
      .toISOString()
      .slice(0, 16);
  }
  element<HTMLDialogElement>("editor").showModal();
}
async function saveEditor() {
  const form = element<HTMLFormElement>("editor-form");
  if (!form.reportValidity()) return;
  const data = Object.fromEntries(new FormData(form));
  const prior = editing;
  const raw = String(data.relationships ?? "").trim();
  const relationships = raw
    ? raw.split("\n").map((line) => {
        const match = line
          .trim()
          .match(
            /^(references|belongs_to|supersedes|related):\s*([a-f0-9-]{36})$/i,
          );
        if (!match)
          throw new Error("Use relationship-type: memory-uuid, one per line.");
        return { type: match[1], target: match[2] };
      })
    : [];
  const expiresAt = data.expiresAt
    ? new Date(String(data.expiresAt)).toISOString()
    : null;
  const result = await api<{ memory: MemoryRecord }>(
    prior ? "/memories/" + encodeURIComponent(prior.id) : "/memories",
    prior ? "PATCH" : "POST",
    {
      ...data,
      relationships,
      expiresAt,
      ...(prior
        ? { expectedRevision: prior.revision }
        : { confidence: "user-confirmed" }),
    },
    editorOperationId,
  );
  element<HTMLDialogElement>("editor").close();
  await loadMemories();
  await showMemory(result.memory);
  notice("Saved as an immutable canonical revision.");
}
async function loadInbox() {
  const result = await api<{ proposals: Proposal[] }>("/inbox");
  const list = element("proposal-list");
  list.replaceChildren();
  if (!result.proposals.length)
    empty(
      list,
      "The Inbox is clear. Only explicitly permitted clients can propose memories.",
    );
  for (const proposal of result.proposals) {
    const card = make("article", "", "panel stack");
    card.append(
      make("h2", proposal.title),
      make("p", proposal.body, "proposal-body"),
      make(
        "p",
        proposal.project +
          " · Proposed by " +
          proposal.clientId +
          " · " +
          proposal.createdAt,
        "meta",
      ),
      make("p", "Source: " + proposal.source, "meta"),
    );
    const title = make("input");
    title.value = proposal.title;
    title.maxLength = 200;
    const body = make("textarea");
    body.value = proposal.body;
    body.rows = 5;
    body.maxLength = 12000;
    const editTitle = make("label", "Review title");
    editTitle.append(title);
    const editBody = make("label", "Review content");
    editBody.append(body);
    card.append(editTitle, editBody);
    const actions = make("div", "", "actions");
    const approve = async (visibility: string) => {
      await api(
        "/inbox/" + encodeURIComponent(proposal.id) + "/approve",
        "POST",
        { title: title.value, body: body.value, visibility },
      );
      await loadInbox();
      notice("Proposal approved into the canonical vault.");
    };
    actions.append(
      button("Approve", async () => approve("approved")),
      button("Keep private", async () => approve("private")),
      button("Reject", async () => {
        await api(
          "/inbox/" + encodeURIComponent(proposal.id) + "/reject",
          "POST",
          {},
        );
        await loadInbox();
      }),
    );
    card.append(actions);
    list.append(card);
  }
}
async function loadOperations() {
  const result = await api<{
    operations: { operationId: string; memoryId: string; createdAt: string }[];
  }>("/operations");
  const target = element("operations");
  target.replaceChildren();
  if (!result.operations.length)
    target.append(make("p", "No incomplete writes.", "fine"));
  for (const op of result.operations) {
    const row = make("div", "", "history-row");
    row.append(
      make("p", op.memoryId + " · " + op.createdAt, "meta"),
      button("Resume safely", async () => {
        await api(
          "/operations/" + encodeURIComponent(op.operationId) + "/resume",
          "POST",
          {},
        );
        await loadOperations();
        notice("The pending canonical write was recovered.");
      }),
    );
    target.append(row);
  }
  const imports = await api<{
    imports: {
      id: string;
      createdAt: string;
      total: number;
      nextIndex: number;
      complete: boolean;
    }[];
  }>("/imports");
  target.append(make("h3", "Import progress"));
  for (const job of imports.imports) {
    const row = make("div", "", "history-row");
    row.append(
      make(
        "p",
        job.nextIndex +
          " of " +
          job.total +
          " records · " +
          job.createdAt +
          (job.complete ? " · complete" : ""),
        "meta",
      ),
    );
    if (!job.complete)
      row.append(
        button("Resume import", async () => {
          await continueImport(job.id);
          await loadOperations();
        }),
      );
    target.append(row);
  }
  if (
    pendingImportCursor &&
    imports.imports.some((j) => j.id === pendingImportCursor && j.complete)
  ) {
    pendingImportCursor = null;
    pendingImportInput = null;
    notice(
      "The previous import completed on the server. No duplicate import was created.",
    );
  }
  if (
    pendingImportCursor &&
    !imports.imports.some((j) => j.id === pendingImportCursor) &&
    pendingImportInput
  )
    target.append(
      button("Retry pending import start safely", async () => {
        await startImport(pendingImportInput!, pendingImportCursor!);
        await loadOperations();
      }),
    );
}
async function exportMemories() {
  const all: MemoryRecord[] = [],
    markdown: { id: string; text: string }[] = [];
  let cursor: string | null = null,
    bytes = 0;
  const seen = new Set<string>();
  do {
    const q = new URLSearchParams({ limit: "50" });
    if (cursor) q.set("cursor", cursor);
    const page = await api<{
      memories: MemoryRecord[];
      markdown: { id: string; text: string }[];
      cursor: string | null;
    }>("/export?" + q);
    bytes += JSON.stringify(page).length;
    if (bytes > 64 * 1024 * 1024)
      throw new Error(
        "Export exceeds the browser memory budget. Copy the canonical vault through Google Drive for a larger export.",
      );
    all.push(...page.memories);
    markdown.push(...page.markdown);
    cursor = page.cursor;
    if (cursor) {
      if (seen.has(cursor))
        throw new Error("Export pagination did not advance.");
      seen.add(cursor);
    }
  } while (cursor);
  const blob = new Blob(
    [
      JSON.stringify(
        {
          schemaVersion: 1,
          exportedAt: new Date().toISOString(),
          memories: all,
          markdown,
        },
        null,
        2,
      ),
    ],
    { type: "application/json" },
  );
  const url = URL.createObjectURL(blob);
  const link = make("a");
  link.href = url;
  link.download =
    "cloudnest-brain-" + new Date().toISOString().slice(0, 10) + ".json";
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  notice("Exported " + all.length + " canonical memory records with Markdown.");
}
async function importMemories(file: File) {
  if (file.size > 512 * 1024)
    throw new Error(
      "Import file exceeds 512 KiB. Split it into smaller reviewed batches.",
    );
  const text = await file.text();
  let parsed: { memories?: MemoryRecord[] };
  if (/\.(md|markdown)$/i.test(file.name)) {
    const match = text.match(
      /^<!-- CloudNest canonical memory v1 -->\r?\n```json\r?\n([\s\S]*?)\r?\n```\r?\n\r?\n([\s\S]*)$/,
    );
    if (match)
      parsed = { memories: [{ ...JSON.parse(match[1]), body: match[2] }] };
    else {
      const project = element<HTMLInputElement>("import-project").value.trim();
      if (!project)
        throw new Error("Choose a project for this plain Markdown note.");
      parsed = {
        memories: [
          {
            id: crypto.randomUUID(),
            project,
            title: (text.match(/^#\s+(.+)$/m)?.[1] ?? file.name).slice(0, 200),
            body: text,
            source: "import:" + file.name,
            category: "knowledge",
            visibility: "private",
            relationships: [],
            expiresAt: null,
            deleted: false,
          } as unknown as MemoryRecord,
        ],
      };
    }
  } else parsed = JSON.parse(text) as { memories?: MemoryRecord[] };
  if (!Array.isArray(parsed.memories) || parsed.memories.length > 20)
    throw new Error(
      "Import expects a JSON memories array with at most 20 records. Relationships within this batch are remapped to the new IDs.",
    );
  if (
    !confirm(
      "Import " +
        parsed.memories.length +
        " records as private new memories? Review imported content before approving it for AI clients. Existing memories are not overwritten.",
    )
  )
    return;
  const records = parsed.memories.map((m) => ({
    id: m.id,
    project: m.project,
    title: m.title,
    body: m.body,
    source: m.source,
    category: m.category,
    visibility: m.visibility,
    expiresAt: m.expiresAt ?? null,
    relationships: m.relationships ?? [],
    deleted: !!m.deleted,
  }));
  const outstanding = await api<{
    imports: { id: string; complete: boolean }[];
  }>("/imports");
  if (pendingImportCursor || outstanding.imports.some((j) => !j.complete))
    throw new Error(
      "A previous import is incomplete. Open Recovery and resume it before starting another file.",
    );
  pendingImportCursor = crypto.randomUUID();
  pendingImportInput = records;
  await startImport(records, pendingImportCursor);
}
interface ImportResult {
  memories: MemoryRecord[];
  unresolvedReferences: unknown[];
  complete: boolean;
  cursor: string | null;
  jobId: string;
  processed: number;
  total: number;
}
async function startImport(records: unknown[], key: string) {
  const result = await api<ImportResult>(
    "/import",
    "POST",
    { memories: records },
    key,
  );
  await continueImport(result.jobId ?? key, result);
}
async function continueImport(id: string, initial?: ImportResult) {
  let result =
    initial ?? (await api<ImportResult>("/import", "POST", { cursor: id }));
  pendingImportCursor = id;
  let steps = 0;
  while (!result.complete) {
    if (!result.cursor || ++steps > 20)
      throw new Error("Import paused. Resume the durable job in Recovery.");
    notice(
      "Importing " + result.processed + " of " + result.total + " records…",
    );
    result = await api<ImportResult>("/import", "POST", {
      cursor: result.cursor,
    });
  }
  pendingImportCursor = null;
  pendingImportInput = null;
  notice(
    "Imported " +
      result.processed +
      " private records. Review each before approving AI access. External references needing review: " +
      result.unresolvedReferences.length +
      ".",
  );
}

async function rebuildIndex() {
  if (
    !reindexCursor &&
    !confirm(
      "Rebuild the index from canonical Drive revisions? Conflicting branches will be quarantined.",
    )
  )
    return;
  let steps = 0;
  do {
    const result = await api<{
      indexed: number;
      conflicts: string[];
      scanned: number;
      complete: boolean;
      cursor: string | null;
    }>("/reindex", "POST", reindexCursor ? { cursor: reindexCursor } : {});
    reindexCursor = result.cursor;
    notice(
      "Rebuild: " +
        result.scanned +
        " canonical objects scanned · " +
        result.conflicts.length +
        " conflicts.",
    );
    if (result.complete) {
      reindexCursor = null;
      notice(
        "Reindexed " +
          result.indexed +
          " memories. Conflicts requiring review: " +
          result.conflicts.length,
      );
      break;
    }
    if (!reindexCursor || ++steps > 1000)
      throw new Error(
        "Rebuild paused at the request budget. Return to Recovery to resume it.",
      );
  } while (unlocked());
  await loadOperations();
}

async function loadGraph() {
  disposeUniverse();
  const q = new URLSearchParams({
    project: element<HTMLInputElement>("graph-project").value,
    limit:
      element<HTMLSelectElement>("quality").value === "cinematic"
        ? "600"
        : element<HTMLSelectElement>("quality").value === "low"
          ? "100"
          : "300",
  });
  graphData = await api<GraphData>("/graph?" + q);
  if (!Array.isArray(graphData.nodes) || !Array.isArray(graphData.edges))
    throw new Error("Invalid graph response.");
  const category = element<HTMLSelectElement>("graph-category");
  for (const name of [
    ...new Set(
      graphData.nodes.map((n) => n.type).filter((n): n is string => !!n),
    ),
  ])
    if (![...category.options].some((o) => o.value === name)) {
      const option = make("option", name);
      option.value = name;
      category.append(option);
    }
  element("graph-summary").textContent =
    graphData.nodes.length +
    " approved memory and archive nodes · " +
    graphData.edges.length +
    " saved relationships. No inferred connections or fabricated activity.";
  const list = element("graph-list");
  list.replaceChildren();
  for (const node of graphData.nodes) {
    const card = button("", async () => selectGraph(node), "memory-card");
    card.append(
      make("strong", node.title ?? node.label ?? node.id),
      make("small", node.project ?? "Approved memory"),
    );
    list.append(card);
  }
  if (!graphData.nodes.length)
    empty(
      list,
      "No approved memories or published archives match this project. Private records remain outside this graph.",
    );
  empty(
    element("graph-detail"),
    "Select a memory, archive, or recorded client to inspect its source.",
  );
  notice(
    "Loaded approved memories and published archive nodes. Connections and access activity come from saved relationships and authorized audit events.",
  );
  await renderGraph();
}
async function selectGraph(node: GraphNode) {
  universe?.focus(node.id);
  if (node.nodeKind === "archive") {
    const result = await api<{ archive: PublishedArchive }>(
      "/archives/" + encodeURIComponent(node.id),
    );
    renderArchiveDetail(result.archive, element("graph-detail"));
    return;
  }
  const result = await api<{ memory: MemoryRecord }>(
    "/memories/" + encodeURIComponent(node.id),
  );
  const detail = element("graph-detail");
  detail.replaceChildren(
    make("h2", result.memory.title),
    make("p", result.memory.body, "body"),
    make("p", "Source: " + result.memory.source, "meta"),
    make(
      "p",
      "Saved relationships: " + result.memory.relationships.length,
      "meta",
    ),
    button("Explore this project", async () => {
      element<HTMLInputElement>("graph-project").value = result.memory.project;
      await loadGraph();
    }),
  );
}
function showClient(id: string) {
  const client = (
    graphData?.clients as
      | {
          id: string;
          projects: string[];
          permissions: string[];
          status: string;
          expiresAt: string;
          lastSeen?: string;
        }[]
      | undefined
  )?.find((c) => c.id === id);
  if (!client) return;
  universe?.focus("client:" + id);
  element("graph-detail").replaceChildren(
    make("h2", client.id),
    make("p", "Authorization: " + client.status, "meta"),
    make("p", "Projects: " + client.projects.join(", "), "meta"),
    make(
      "p",
      "Permissions: read" +
        (client.permissions.includes("propose") ? ", propose to Inbox" : ""),
      "meta",
    ),
    make("p", "Expires: " + client.expiresAt, "meta"),
    make("p", "Last recorded access: " + (client.lastSeen ?? "none"), "meta"),
  );
}

function updateGraphImageButton() {
  element<HTMLButtonElement>("save-graph-image").disabled =
    busy ||
    !unlocked() ||
    currentView !== "universe" ||
    !universe ||
    !universeMode ||
    element<HTMLSelectElement>("graph-mode").value !== universeMode;
}
function disposeUniverse() {
  universe?.dispose();
  universe = null;
  universeMode = null;
  updateGraphImageButton();
}
async function saveGraphImage() {
  const current = universe,
    mode = universeMode,
    generation = sessionGeneration;
  if (
    !unlocked() ||
    currentView !== "universe" ||
    !current ||
    !mode ||
    element<HTMLSelectElement>("graph-mode").value !== mode
  ) {
    throw new Error("Open Galaxy or Orbit before saving a graph image.");
  }
  const image = await current.capturePNG();
  if (
    generation !== sessionGeneration ||
    universe !== current ||
    universeMode !== mode ||
    currentView !== "universe" ||
    !unlocked()
  )
    return;
  download(
    image,
    mode === "galaxy" ? "CloudNest-Galaxy.png" : "CloudNest-Orbit.png",
  );
  notice(
    "Current " +
      (mode === "galaxy" ? "Galaxy" : "Orbit") +
      " image prepared. Your browser handles the PNG download; only the displayed graph is included.",
  );
}
async function renderGraph() {
  const generation = sessionGeneration;
  disposeUniverse();
  const quality = element<HTMLSelectElement>("quality").value;
  const since = element<HTMLInputElement>("graph-date").value;
  const shownGraph = graphData
    ? filterGraph(
        boundedGraph(
          graphData,
          quality === "low" ? 100 : quality === "cinematic" ? 600 : 300,
        ),
        {
          category: element<HTMLSelectElement>("graph-category").value,
          source: element<HTMLInputElement>("graph-source").value,
          since: since ? since + "T00:00:00.000Z" : "",
        },
      )
    : null;
  visibleGraph = shownGraph;
  const mode = element<HTMLSelectElement>("graph-mode").value;
  const stage = element("graph-stage");
  stage.hidden = mode === "list";
  if (shownGraph)
    element("graph-summary").textContent =
      shownGraph.nodes.length +
      " visible approved memory and archive nodes · " +
      shownGraph.edges.length +
      " saved relationships" +
      (graphData?.truncated
        ? " · recent-node budget reached; narrow the project to explore more."
        : ". Filters apply within the loaded node set.");
  if (mode === "orbit" && shownGraph) {
    const list = element("graph-list");
    list.replaceChildren();
    for (const client of shownGraph.clients as {
      id: string;
      status: string;
    }[]) {
      const card = button("", async () => showClient(client.id), "memory-card");
      card.dataset.graphTitle = client.id.toLowerCase();
      card.append(
        make("strong", client.id),
        make("small", client.status + " · recorded access"),
      );
      list.append(card);
    }
    if (!shownGraph.clients.length)
      empty(
        list,
        "No recorded authorized client reads for these nodes. Connect a scoped client and retrieve approved memory or archive metadata first.",
      );
  }
  if (mode !== "orbit" && shownGraph) {
    const list = element("graph-list");
    list.replaceChildren();
    for (const node of shownGraph.nodes) {
      const card = button("", async () => selectGraph(node), "memory-card");
      card.dataset.graphTitle = (
        node.title ??
        node.label ??
        node.id
      ).toLowerCase();
      card.append(
        make("strong", node.title ?? node.label ?? node.id),
        make("small", node.project ?? "Approved memory"),
      );
      list.append(card);
    }
    if (!shownGraph.nodes.length)
      empty(
        list,
        "No approved memories or published archives match these filters.",
      );
  }
  if ((mode !== "galaxy" && mode !== "orbit") || !shownGraph) return;
  try {
    const module = await import("../graph/universe");
    if (
      generation !== sessionGeneration ||
      currentView !== "universe" ||
      !unlocked()
    )
      return;
    universe = module.createUniverse(stage, shownGraph, {
      mode,
      quality: element<HTMLSelectElement>("quality").value,
      reducedMotion: matchMedia("(prefers-reduced-motion: reduce)").matches,
      onSelect: (id: string) => {
        if (id.startsWith("client:")) {
          showClient(id.slice(7));
          return;
        }
        const node = graphData?.nodes.find((n) => n.id === id);
        if (node) void run(async () => selectGraph(node));
      },
    });
    universeMode = mode;
    updateGraphImageButton();
  } catch (error) {
    if (generation !== sessionGeneration) return;
    console.warn(
      "CloudNest graph could not load:",
      error instanceof Error
        ? error.message.slice(0, 200)
        : "Unknown renderer error",
    );
    stage.hidden = true;
    element<HTMLSelectElement>("graph-mode").value = "list";
    notice(
      "3D could not be opened. The accessible graph list remains fully usable; you can try the view again.",
      true,
    );
  }
}
for (const control of document.querySelectorAll<HTMLButtonElement>(
  "nav button",
))
  control.addEventListener("click", () => {
    void run(async () => view(control.dataset.view ?? "memories"));
  });
async function openConsole() {
  const status = await api<{
    configured: boolean;
    canonical: boolean;
    reindexJob?: string | null;
  }>("/status");
  if (
    (!status.configured || !status.canonical) &&
    !["authorize", "connections", "archives"].includes(currentView)
  ) {
    lock();
    throw new Error(
      "Configure a dedicated canonical Drive vault before adding personal memories.",
    );
  }
  canonicalReady = status.canonical;
  reindexCursor = status.reindexJob ?? null;
  if (reindexCursor && !["authorize", "archives"].includes(currentView))
    currentView = "recovery";
  element("login").hidden = true;
  element("lock").hidden = false;
  element("connection-status").textContent = browserSession.state.authenticated
    ? "Signed in with passkey"
    : status.canonical
      ? "Advanced owner access"
      : "Owner authorized · Brain not configured";
  element("connection-dot").classList.add("connected");
  await view(currentView);
}
element<HTMLInputElement>("owner-connection-file").addEventListener("change", (event) => {
  const input = event.target as HTMLInputElement, file = input.files?.[0];
  input.value = "";
  if (!file) return;
  if (busy) { notice("Finish the current action, then choose the owner connection file again.", true); return; }
  const generation = sessionGeneration;
  element<HTMLInputElement>("token").value = "";
  element<HTMLInputElement>("token").required = true;
  element("owner-connection-status").textContent = "Checking connection file locally…";
  void run(async () => {
    try {
      const loaded = await localOwnerConnection.load(file);
      if (!loaded || generation !== sessionGeneration) return;
      element<HTMLInputElement>("token").required = false;
      element("owner-connection-status").textContent = "Owner connection loaded in tab memory. Choose Set up passkey or Use advanced owner access. No request has been sent.";
    } catch (error) {
      if (generation === sessionGeneration) { element<HTMLInputElement>("token").required = true; element("owner-connection-status").textContent = "Connection file was not loaded. No request was sent."; }
      throw error;
    }
  });
});
element<HTMLFormElement>("login-form").addEventListener("submit", (event) => {
  event.preventDefault();
  void run(async () => {
    credential = element<HTMLInputElement>("token").value.trim() || localOwnerConnection.take();
    localOwnerConnection.clear();
    element("owner-connection-status").textContent = "Local owner connection consumed; no copy is saved in the browser.";
    element<HTMLInputElement>("token").required = true;
    element<HTMLInputElement>("token").value = "";
    if (credential.length < 32) { credential = ""; throw new Error("Choose an owner connection file or enter your owner recovery credential first."); }
    try {
      await openConsole();
    } catch (error) {
      credential = "";
      throw error;
    }
  });
});
element("passkey-sign-in").addEventListener("click", () => {
  void run(async () => {
    await browserSession.signIn();
    localOwnerConnection.clear();
    element<HTMLInputElement>("token").required = true;
    element("owner-connection-status").textContent = "Local owner connection cleared after passkey sign-in.";
    credential = "";
    await openConsole();
    notice(
      "Signed in. Your owner recovery credential is not needed for everyday access.",
    );
  });
});
async function enrollPasskey(recoveryField: string, labelField?: string) {
  const field = element<HTMLInputElement>(recoveryField),
    recovery = field.value.trim() || (recoveryField === "token" ? localOwnerConnection.take() : "");
  if (recovery.length < 32)
    throw new Error(
      "Enter the current owner recovery credential once to authorize passkey setup.",
    );
  const label = labelField
    ? element<HTMLInputElement>(labelField).value.trim()
    : "My passkey";
  field.value = "";
  if (recoveryField === "token") { localOwnerConnection.clear(); field.required = true; element("owner-connection-status").textContent = "Local owner connection consumed for this explicit enrollment attempt."; }
  await browserSession.register(recovery, label || "My passkey");
  credential = "";
  await openConsole();
  notice("Passkey enrolled. Future visits can sign in with your device.");
}
element("passkey-register").addEventListener("click", () => {
  void run(() => enrollPasskey("token"));
});
element<HTMLFormElement>("passkey-enrollment-form").addEventListener(
  "submit",
  (event) => {
    event.preventDefault();
    void run(() => enrollPasskey("passkey-recovery", "passkey-label"));
  },
);
async function signOut(all = false) {
  const wasBrowser = browserSession.state.authenticated;
  if (!wasBrowser) {
    lock();
    return;
  }
  const request = browserSession.signOut(all);
  lock(true);
  try {
    await request;
    notice(
      all
        ? "Signed out of all browser sessions."
        : "Signed out of this browser. Use your passkey when you return.",
    );
  } catch {
    browserSession.clear();
    notice(
      "This tab is cleared, but browser sign-out could not be confirmed while offline. Reconnect and sign out before leaving a shared device.",
      true,
    );
  }
}
element("lock").addEventListener("click", () => {
  void signOut();
});
element("sign-out-all").addEventListener("click", () => {
  void run(async () => {
    if (!browserSession.state.authenticated)
      throw new Error("Sign in with a passkey to manage browser sessions.");
    if (
      confirm(
        "Sign out of every browser session? Your passkeys remain enrolled.",
      )
    )
      await signOut(true);
  });
});
element("refresh").addEventListener("click", () => {
  void run(async () => view(currentView));
});
element<HTMLFormElement>("search-form").addEventListener("submit", (e) => {
  e.preventDefault();
  void run(async () => loadMemories());
});
element("more").addEventListener("click", () => {
  void run(async () => loadMemories(true));
});
element<HTMLFormElement>("archive-search-form").addEventListener(
  "submit",
  (event) => {
    event.preventDefault();
    void run(async () => loadArchives(null, []));
  },
);
element("archive-next").addEventListener("click", () => {
  if (archiveNextCursor)
    void run(async () =>
      loadArchives(archiveNextCursor, [...archiveHistory, archiveCursor]),
    );
});
element("archive-previous").addEventListener("click", () => {
  if (archiveHistory.length)
    void run(async () =>
      loadArchives(archiveHistory.at(-1) ?? null, archiveHistory.slice(0, -1)),
    );
});
element("refresh-restore-queue").addEventListener("click", () => {
  void run(loadRestoreQueue);
});
element("new-memory").addEventListener("click", () => openEditor(null));
element("close-editor").addEventListener("click", () =>
  element<HTMLDialogElement>("editor").close(),
);
element<HTMLFormElement>("editor-form").addEventListener("submit", (e) => {
  e.preventDefault();
  void run(saveEditor);
});
element<HTMLFormElement>("handoff-form").addEventListener("submit", (e) => {
  e.preventDefault();
  void run(async () => {
    const data: Record<string, unknown> = Object.fromEntries(
      new FormData(element<HTMLFormElement>("handoff-form")),
    );
    data.references = String(data.references ?? "")
      .split("\n")
      .map((x) => x.trim())
      .filter(Boolean);
    const result = await api<{ text: string }>("/handoff", "POST", data);
    element<HTMLTextAreaElement>("handoff-text").value = result.text;
    notice(
      "Handoff prepared for " +
        element<HTMLSelectElement>("destination").value +
        ". Review it before sharing.",
    );
  });
});
element("copy-handoff").addEventListener("click", () => {
  void run(async () => {
    await navigator.clipboard.writeText(
      element<HTMLTextAreaElement>("handoff-text").value,
    );
    notice("Handoff copied. Paste it into your chosen assistant.");
  });
});
element<HTMLTextAreaElement>("handoff-text").addEventListener("input", () => {
  element<HTMLButtonElement>("copy-handoff").disabled =
    !element<HTMLTextAreaElement>("handoff-text").value;
  element<HTMLButtonElement>("copy-client-token").disabled =
    !element<HTMLInputElement>("client-token").value;
});
element("export").addEventListener("click", () => {
  void run(exportMemories);
});
element<HTMLInputElement>("import-file").addEventListener("change", (event) => {
  const input = event.target as HTMLInputElement;
  const file = input.files?.[0];
  if (file)
    void run(async () => {
      await importMemories(file);
      input.value = "";
    });
});
element("reindex").addEventListener("click", () => {
  void run(rebuildIndex);
});
element<HTMLFormElement>("graph-form").addEventListener("submit", (e) => {
  e.preventDefault();
  void run(loadGraph);
});
element("save-graph-image").addEventListener("click", () => {
  void run(saveGraphImage);
});
element("graph-mode").addEventListener("change", () => {
  updateGraphImageButton();
  void run(renderGraph);
});
element("quality").addEventListener("change", () => {
  void run(loadGraph);
});
addEventListener("blur", () => universe?.setActive(false));
addEventListener("focus", () => universe?.setActive(!document.hidden));
document.addEventListener("visibilitychange", () =>
  universe?.setActive(!document.hidden && document.hasFocus()),
);
const conversationPanel = new ConversationPanel({api,run,notice,unlocked,confirm:message=>confirm(message)});
addEventListener("pagehide", () => lock());
addEventListener("keydown", (event) => {
  if (event.key === "Escape" && element<HTMLDialogElement>("editor").open)
    element<HTMLDialogElement>("editor").close();
  if ((event.metaKey || event.ctrlKey) && event.key === "k") {
    event.preventDefault();
    if (unlocked())
      void run(async () => {
        await view("memories");
        element<HTMLInputElement>("query").focus();
      });
  }
});
if (authorizationRequest) {
  currentView = "authorize";
  element("page-title").textContent = titles.authorize;
}
const initial = location.hash.slice(1);
if (initial in titles) {
  currentView = initial;
  element("page-title").textContent = titles[initial];
}
export {};

interface ConnectedClient {
  id: string;
  projects: string[];
  permissions: string[];
  expiresAt: string;
  status: string;
  lastSeen: string | null;
  managed: boolean;
  oauth?: boolean;
}
async function loadPasskeys() {
  const generation = sessionGeneration;
  await browserSession.inspect();
  const result = await browserSession.call<{passkeys:{id:string;label:string;createdAt:number;lastUsedAt:number|null;current:boolean}[]}>("/passkeys", undefined, credential || undefined);
  if (generation !== sessionGeneration) return;
  const list = element("passkey-list");
  list.replaceChildren();
  if (!result.passkeys.length) empty(list,"No passkeys enrolled. Use Add a passkey to set up device sign-in.");
  for (const key of result.passkeys) {
    const card = make("article", "", "history-row"), description = make("div");
    description.append(make("h3", key.label + (key.current ? " · this browser" : "")), make("p", "Added " + new Date(key.createdAt).toLocaleString() + (key.lastUsedAt ? " · last used " + new Date(key.lastUsedAt).toLocaleString() : ""), "fine"));
    const remove = make("button", "Remove…") as HTMLButtonElement;
    remove.type = "button";
    remove.addEventListener("click", () => void run(async () => {
      const last = result.passkeys.length === 1;
      const field = element<HTMLInputElement>("passkey-recovery");
      const recovery = last ? (field.value.trim() || credential) : credential;
      if (last && recovery.length < 32) throw new Error("Enter your current owner recovery credential in Add a passkey before removing the final passkey. It is never saved in the browser.");
      if (!confirm(`Remove ${key.label}? Browsers using this passkey will be signed out.${last ? " This is your final passkey. Future access will require your owner recovery credential until you enroll another." : ""}`)) return;
      field.value = "";
      await browserSession.inspect();
      const outcome = await browserSession.call<{revoked:boolean;signedOut:boolean}>("/passkeys/revoke", {id:key.id,...(last ? {allowLastPasskeyRemoval:true} : {})}, recovery || undefined);
      if (outcome.signedOut) { lock(); notice("Passkey removed and this browser signed out. Use another passkey or advanced owner recovery access."); }
      else { await loadPasskeys(); notice("Passkey removed. Its browser sessions were revoked."); }
    }));
    card.append(description,remove);list.append(card);
  }
}
async function loadConnections() {
  await loadPasskeys();
  const result = canonicalReady
    ? await api<{ clients: ConnectedClient[] }>("/clients")
    : {
        clients: (await api<{ grants: ConnectedClient[] }>("/oauth/grants"))
          .grants,
      };
  element("client-form").hidden = !canonicalReady;
  const list = element("client-list");
  list.replaceChildren();
  if (!result.clients.length)
    empty(list, "No clients have been granted access.");
  for (const client of result.clients) {
    const card = make("article", "", "history-row");
    const description = make("div");
    description.append(
      make("h3", client.id),
      make(
        "p",
        client.status +
          " · " +
          client.projects.join(", ") +
          " · read" +
          (client.permissions.includes("propose") ? ", Inbox proposals" : ""),
        "meta",
      ),
      make(
        "p",
        "Expires " +
          client.expiresAt +
          " · Last seen " +
          (client.lastSeen ?? "no recorded requests"),
        "meta",
      ),
    );
    card.append(description);
    if (client.status !== "revoked")
      card.append(
        button("Revoke…", async () => {
          if (
            !confirm(
              "Revoke " +
                client.id +
                "? Its current credential will stop working.",
            )
          )
            return;
          await api(
            (client.oauth ? "/oauth/grants/" : "/clients/") +
              encodeURIComponent(client.id) +
              "/revoke",
            "POST",
            {},
          );
          await loadConnections();
        }),
      );
    list.append(card);
  }
  if (!canonicalReady) {
    empty(
      element("audit-list"),
      "OAuth grants are available for review and revocation. Complete the dedicated Brain connection for the full memory audit view.",
    );
    return;
  }
  const audit = await api<{
    events: {
      id: number;
      clientId: string;
      action: string;
      memoryId: string | null;
      createdAt: string;
    }[];
  }>("/audit");
  const log = element("audit-list");
  log.replaceChildren();
  if (!audit.events.length) empty(log, "No recorded access yet.");
  for (const event of audit.events) {
    const row = make("div", "", "history-row");
    row.append(
      make(
        "p",
        event.clientId +
          " · " +
          event.action +
          (event.memoryId ? " · " + event.memoryId : ""),
        "meta",
      ),
      make("time", event.createdAt, "meta"),
    );
    log.append(row);
  }
  const expiry = element<HTMLFormElement>("client-form").elements.namedItem(
    "expiry",
  ) as HTMLInputElement;
  if (!expiry.value) {
    const date = new Date(Date.now() + 30 * 86400000);
    expiry.value = new Date(date.getTime() - date.getTimezoneOffset() * 60000)
      .toISOString()
      .slice(0, 16);
  }
}
function projectIDs(text: string) {
  const projects = [
    ...new Set(
      text
        .split("\n")
        .map((x) => x.trim())
        .filter(Boolean),
    ),
  ];
  if (
    !projects.length ||
    projects.length > 32 ||
    projects.some((p) => !/^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/.test(p))
  )
    throw new Error(
      "Enter 1–32 project IDs, one per line, using letters, numbers, periods, underscores or hyphens.",
    );
  return projects;
}
async function createClient() {
  const form = element<HTMLFormElement>("client-form");
  if (!form.reportValidity()) return;
  const input = new FormData(form);
  const result = await api<{ token: string }>("/clients", "POST", {
    id: String(input.get("id")),
    projects: projectIDs(String(input.get("projects"))),
    expiresAt: new Date(String(input.get("expiry"))).toISOString(),
    permissions: input.has("propose") ? ["propose"] : [],
  });
  element<HTMLInputElement>("client-token").value = result.token;
  element<HTMLButtonElement>("copy-client-token").disabled = false;
  await loadConnections();
  notice(
    "Scoped client created. Copy its credential now; it will not be shown by the server again.",
  );
}
async function loadDeleted(append = false) {
  const q = new URLSearchParams({ limit: "20" });
  if (append && deletedCursor) q.set("cursor", deletedCursor);
  const result = await api<{ memories: MemoryRecord[]; cursor: string | null }>(
    "/deleted?" + q,
  );
  deletedCursor = result.cursor;
  const list = element("deleted-list");
  if (!append) list.replaceChildren();
  if (!result.memories.length && !append) empty(list, "No deleted memories.");
  for (const memory of result.memories) {
    const row = make("article", "", "stack history-row");
    row.append(
      make("h3", memory.title),
      make(
        "p",
        "Deleted revision " + memory.version + " · " + memory.updatedAt,
        "meta",
      ),
      button("Review revision history", async () =>
        showHistory(memory, null, row),
      ),
    );
    list.append(row);
  }
  element("deleted-more").hidden = !deletedCursor;
}
async function loadSuggestions() {
  const result = await api<{
    duplicates: { ids: string[]; reason: string }[];
    possibleConflicts: { ids: string[]; reason: string }[];
  }>("/suggestions");
  const list = element("suggestion-list");
  list.replaceChildren();
  if (!result.duplicates.length && !result.possibleConflicts.length)
    empty(list, "No suggestions within the bounded comparison set.");
  for (const suggestion of [
    ...result.duplicates,
    ...result.possibleConflicts,
  ]) {
    const row = make("article", "", "stack history-row");
    row.append(make("p", suggestion.reason, "meta"));
    const [first, second] = suggestion.ids;
    if (first && second)
      row.append(
        button("Review both memories", async () => {
          const [a, b] = await Promise.all([
            api<{ memory: MemoryRecord }>(
              "/memories/" + encodeURIComponent(first),
            ),
            api<{ memory: MemoryRecord }>(
              "/memories/" + encodeURIComponent(second),
            ),
          ]);
          const review = make("section", "", "stack");
          review.append(
            make("h3", a.memory.title + " / " + b.memory.title),
            make("p", "First: " + a.memory.body, "proposal-body"),
            make("p", "Second: " + b.memory.body, "proposal-body"),
            make("p", "First source: " + a.memory.source + " · updated " + a.memory.updatedAt + " · " + a.memory.visibility + " · " + a.memory.confidence, "meta"),
            make("p", "Second source: " + b.memory.source + " · updated " + b.memory.updatedAt + " · " + b.memory.visibility + " · " + b.memory.confidence, "meta"),
            make("p", "Check the original sources and current project decisions before replacing either fact. Matching text or titles alone do not establish which memory is correct.", "fine"),
          );
          const content = make("textarea");
          content.rows = 8;
          content.maxLength = 12000;
          content.value =
            a.memory.body === b.memory.body
              ? a.memory.body
              : a.memory.body + "\n\n" + b.memory.body;
          const label = make("label", "Review merged text");
          label.append(content);
          review.append(
            label,
            button("Save merge and delete second…", async () => {
              if (
                !confirm(
                  "Save this reviewed text to the first memory, then tombstone the second? This uses two version-checked operations. A conflict can leave the second intact; history remains available.",
                )
              )
                return;
              const saved = await api<{ memory: MemoryRecord }>(
                "/memories/" + encodeURIComponent(a.memory.id),
                "PATCH",
                {
                  expectedRevision: a.memory.revision,
                  body: content.value,
                  visibility:
                    a.memory.visibility === "private" ||
                    b.memory.visibility === "private"
                      ? "private"
                      : "approved",
                },
              );
              notice(
                "Merged revision saved. Deleting the duplicate with its original revision guard…",
              );
              await api(
                "/memories/" + encodeURIComponent(b.memory.id),
                "DELETE",
                { expectedRevision: b.memory.revision },
              );
              await view("memories");
              await showMemory(saved.memory);
              notice(
                "Merge saved and the second memory tombstoned. Both histories remain recoverable.",
              );
            }),
          );
          row.append(review);
        }),
      );
    list.append(row);
  }
}
interface ConsentRequest {
  id: string;
  clientId: string;
  clientName: string;
  redirectUri: string;
  resource: string;
  scopes: string[];
  createdAt: string;
  expiresAt: string;
  status: string;
}
let consentRequest: ConsentRequest | null = null;
async function loadConsent() {
  if (!authorizationRequest || !/^[a-f0-9-]{36}$/i.test(authorizationRequest))
    throw new Error(
      "Invalid authorization request. Start the connection again from the AI client.",
    );
  const result = await api<{ request: ConsentRequest }>(
    "/oauth/requests/" + encodeURIComponent(authorizationRequest),
  );
  consentRequest = result.request;
  const target = element("consent-details");
  target.replaceChildren();
  for (const [label, value] of Object.entries({
    Client: result.request.clientName,
    "Client ID": result.request.clientId,
    "Redirect destination": result.request.redirectUri,
    Resource: result.request.resource,
    "Requested scopes": result.request.scopes.join(", "),
    Expires: result.request.expiresAt,
  }))
    target.append(make("h3", label), make("p", value, "meta"));
  element("consent-propose-label").hidden =
    !result.request.scopes.includes("memory:propose");
  element<HTMLInputElement>("consent-propose").checked = false;
}
async function decideConsent(approve: boolean) {
  if (!consentRequest || !authorizationRequest)
    throw new Error("Load the client request first.");
  const result = await api<{ redirectUrl: string }>(
    "/oauth/requests/" +
      encodeURIComponent(authorizationRequest) +
      (approve ? "/approve" : "/deny"),
    "POST",
    approve
      ? {
          projects: projectIDs(
            element<HTMLTextAreaElement>("consent-projects").value,
          ),
          permissions:
            consentRequest.scopes.includes("memory:propose") &&
            element<HTMLInputElement>("consent-propose").checked
              ? ["propose"]
              : [],
        }
      : {},
  );
  const destination = new URL(result.redirectUrl);
  if (
    destination.username ||
    destination.password ||
    (destination.protocol !== "https:" &&
      !(
        destination.protocol === "http:" &&
        ["localhost", "127.0.0.1", "[::1]"].includes(destination.hostname)
      ))
  )
    throw new Error("The client redirect was rejected.");
  credential = "";
  location.assign(destination.href);
}
element<HTMLFormElement>("client-form").addEventListener("submit", (e) => {
  e.preventDefault();
  void run(createClient);
});
element("copy-client-token").addEventListener("click", () => {
  void run(async () =>
    navigator.clipboard.writeText(
      element<HTMLInputElement>("client-token").value,
    ),
  );
});
element("clear-client-token").addEventListener("click", () => {
  element<HTMLInputElement>("client-token").value = "";
  element<HTMLButtonElement>("copy-client-token").disabled = true;
});
element("load-deleted").addEventListener("click", () => {
  void run(async () => loadDeleted());
});
element("deleted-more").addEventListener("click", () => {
  void run(async () => loadDeleted(true));
});
element("load-suggestions").addEventListener("click", () => {
  void run(loadSuggestions);
});
element<HTMLFormElement>("consent-form").addEventListener("submit", (e) => {
  e.preventDefault();
  void run(async () => decideConsent(true));
});
element("deny-consent").addEventListener("click", () => {
  void run(async () => decideConsent(false));
});
element<HTMLInputElement>("graph-search").addEventListener("input", () => {
  const term = element<HTMLInputElement>("graph-search").value.toLowerCase();
  const cards = [
    ...element("graph-list").querySelectorAll<HTMLElement>(".memory-card"),
  ];
  for (const card of cards)
    card.hidden = !!term && !card.dataset.graphTitle?.includes(term);
  const matches =
    visibleGraph?.nodes.filter((n) =>
      (n.title ?? n.label ?? n.id).toLowerCase().includes(term),
    ) ?? [];
  const exact =
    matches.find((n) => (n.title ?? n.label ?? n.id).toLowerCase() === term) ??
    (term && matches.length === 1 ? matches[0] : undefined);
  if (exact) universe?.focus(exact.id);
});

for (const id of ["graph-category", "graph-source", "graph-date"])
  element(id).addEventListener("change", () => {
    void run(renderGraph);
  });

element("project-context").addEventListener("click", () => {
  void run(async () => {
    const project = String(
      new FormData(element<HTMLFormElement>("handoff-form")).get("project") ??
        "",
    ).trim();
    if (!project) throw new Error("Choose a project for this context pack.");
    const result = await api<{ text: string }>(
      "/context?" + new URLSearchParams({ project }),
    );
    element<HTMLTextAreaElement>("handoff-text").value = result.text;
    notice("Approved project context prepared. Review before sharing.");
  });
});

// Restore only an HttpOnly server session on reload. Never persist credentials.
void (async () => {
  element<HTMLButtonElement>("passkey-sign-in").disabled =
    !browserSession.supported;
  element<HTMLButtonElement>("passkey-register").disabled =
    !browserSession.supported;
  if (!browserSession.supported)
    element("passkey-status").textContent =
      "This browser needs HTTPS and passkey support. Advanced owner access is available below.";
  try {
    const state = await browserSession.inspect();
    if (state.authenticated) {
      await run(openConsole);
    } else if (browserSession.supported)
      element("passkey-status").textContent = state.passkeys
        ? "Use Touch ID, a device PIN, or your security key to sign in."
        : "First visit? Authorize passkey setup once using advanced owner access below.";
  } catch (error) {
    element("passkey-status").textContent =
      error instanceof Error
        ? error.message
        : "Sign-in is unavailable. Check your connection.";
  }
})();
setInterval(() => {
  const state = browserSession.state;
  if (
    state.authenticated &&
    Date.now() >= Math.min(state.idleUntil ?? 0, state.absoluteUntil ?? 0)
  ) {
    lock();
    notice(
      "Your browser session expired. Sign in again with your passkey.",
      true,
    );
  }
}, 15000);
