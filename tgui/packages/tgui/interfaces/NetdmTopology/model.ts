/**
 * Renderer-independent model of the netDM topology screen: wire data parsing,
 * deltas by stable ID, viewport math and hit testing. PixiJS lives in scene.ts.
 */

/** Node flags from the Host view. */
export const FLAG_RELAY = 1;
export const FLAG_RADIO = 2;
export const FLAG_ACCESS_POINT = 4;
export const FLAG_DEVICE = 8;
export const FLAG_APC = 16;
export const FLAG_UNPOWERED = 32;
export const FLAG_BROKEN = 64;

/** A node without power or out of order keeps its place and attachment but carries no traffic. */
export const isOffline = (flags: number) => (flags & (FLAG_UNPOWERED | FLAG_BROKEN)) !== 0;

export type NodeKind = 'apc' | 'device' | 'node';

export type ViewNode = {
  id: string;
  x: number;
  y: number;
  flags: number;
};

export type ViewLink = {
  id: string;
  a: string;
  b: string;
  radio: boolean;
  /** A wired link that exists in the world but is silent because one of its ends is inactive. */
  down: boolean;
};

export type View = {
  nodes: Map<string, ViewNode>;
  links: Map<string, ViewLink>;
};

/** Rows as sent by DM: nodes [id, x, y, flags], wired, radio and silent wired links [a, b]. */
export type ViewRows = {
  nodes?: unknown[];
  edges?: unknown[];
  radio?: unknown[];
  down?: unknown[];
};

/** Upper bounds the client enforces whatever the server sends. */
export const MAX_NODES = 4096;
export const MAX_LINKS = 8192;

export const kindOf = (flags: number): NodeKind => {
  if (flags & FLAG_APC || flags & FLAG_ACCESS_POINT) {
    return 'apc';
  }
  return flags & FLAG_DEVICE ? 'device' : 'node';
};

export const linkId = (a: string, b: string, radio: boolean, down = false) =>
  `${radio ? 'r' : down ? 'd' : 'w'}:${a < b ? a : b}:${a < b ? b : a}`;

const isRow = (row: unknown, size: number): row is unknown[] =>
  Array.isArray(row) && row.length >= size;

/** Parses rows defensively: malformed entries are skipped, not fatal. */
export const parseView = (rows: ViewRows): View => {
  const nodes = new Map<string, ViewNode>();
  for (const row of rows.nodes ?? []) {
    if (nodes.size >= MAX_NODES) {
      break;
    }
    if (!isRow(row, 4)) {
      continue;
    }
    const [id, x, y, flags] = row;
    if (typeof id !== 'string' || typeof x !== 'number' || typeof y !== 'number') {
      continue;
    }
    nodes.set(id, { id, x, y, flags: typeof flags === 'number' ? flags : 0 });
  }
  const links = new Map<string, ViewLink>();
  const addLinks = (list: unknown[] | undefined, radio: boolean, down: boolean) => {
    for (const row of list ?? []) {
      if (links.size >= MAX_LINKS) {
        return;
      }
      if (!isRow(row, 2)) {
        continue;
      }
      const [a, b] = row;
      if (typeof a !== 'string' || typeof b !== 'string' || !nodes.has(a) || !nodes.has(b)) {
        continue;
      }
      const id = linkId(a, b, radio, down);
      links.set(id, { id, a, b, radio, down });
    }
  };
  addLinks(rows.edges, false, false);
  addLinks(rows.radio, true, false);
  addLinks(rows.down, false, true);
  return { nodes, links };
};

export type Delta<T> = {
  added: T[];
  changed: T[];
  removed: string[];
};

/** Keyed delta between two snapshots; unchanged entries are not touched. */
export const diffById = <T extends { id: string }>(
  previous: Map<string, T>,
  next: Map<string, T>,
  same: (left: T, right: T) => boolean,
): Delta<T> => {
  const delta: Delta<T> = { added: [], changed: [], removed: [] };
  for (const [id, value] of next) {
    const old = previous.get(id);
    if (!old) {
      delta.added.push(value);
    } else if (!same(old, value)) {
      delta.changed.push(value);
    }
  }
  for (const id of previous.keys()) {
    if (!next.has(id)) {
      delta.removed.push(id);
    }
  }
  return delta;
};

export const sameNode = (left: ViewNode, right: ViewNode) =>
  left.x === right.x && left.y === right.y && left.flags === right.flags;

export const sameLink = (left: ViewLink, right: ViewLink) =>
  left.a === right.a && left.b === right.b && left.radio === right.radio && left.down === right.down;

/** World units per tile on screen at scale 1. BYOND Y grows north, screen Y grows down. */
export const TILE = 8;
export const toWorld = (node: { x: number; y: number }) => ({ x: node.x * TILE, y: -node.y * TILE });

export type Viewport = { x: number; y: number; scale: number };

export const MIN_SCALE = 0.05;
export const MAX_SCALE = 8;

const clampScale = (scale: number) => Math.min(MAX_SCALE, Math.max(MIN_SCALE, scale));

/** Zooms around a screen point so the world point under the cursor stays put. */
export const zoomAt = (view: Viewport, factor: number, screenX: number, screenY: number): Viewport => {
  const scale = clampScale(view.scale * factor);
  const worldX = (screenX - view.x) / view.scale;
  const worldY = (screenY - view.y) / view.scale;
  return { x: screenX - worldX * scale, y: screenY - worldY * scale, scale };
};

export const screenToWorld = (view: Viewport, screenX: number, screenY: number) => ({
  x: (screenX - view.x) / view.scale,
  y: (screenY - view.y) / view.scale,
});

/** Fits every node into the screen with a margin; an empty view keeps the current viewport. */
export const fitView = (nodes: Iterable<ViewNode>, width: number, height: number, current: Viewport): Viewport => {
  let minX = Infinity;
  let minY = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;
  for (const node of nodes) {
    const point = toWorld(node);
    minX = Math.min(minX, point.x);
    minY = Math.min(minY, point.y);
    maxX = Math.max(maxX, point.x);
    maxY = Math.max(maxY, point.y);
  }
  if (!Number.isFinite(minX) || width <= 0 || height <= 0) {
    return current;
  }
  const margin = 4 * TILE;
  const spanX = maxX - minX + 2 * margin;
  const spanY = maxY - minY + 2 * margin;
  const scale = clampScale(Math.min(width / spanX, height / spanY));
  return {
    scale,
    x: width / 2 - ((minX + maxX) / 2) * scale,
    y: height / 2 - ((minY + maxY) / 2) * scale,
  };
};

/** Nearest node within `radius` world units, or null. Linear: the view is bounded by MAX_NODES. */
export const nearestNode = (nodes: Iterable<ViewNode>, worldX: number, worldY: number, radius: number) => {
  let best: ViewNode | null = null;
  let bestDistance = radius * radius;
  for (const node of nodes) {
    const point = toWorld(node);
    const dx = point.x - worldX;
    const dy = point.y - worldY;
    const distance = dx * dx + dy * dy;
    if (distance <= bestDistance) {
      best = node;
      bestDistance = distance;
    }
  }
  return best;
};
