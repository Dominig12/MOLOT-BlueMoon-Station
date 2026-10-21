import { NetEdge } from './types';

/** Layout input deliberately excludes station coordinates. */
type LayoutNode = { address: string; type: string; uplink?: string | null };
export type GraphPoint = { px: number; py: number };
export const graphBounds = (points: Iterable<GraphPoint>, padding = 100) => {
  let minX = Infinity;
  let minY = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;
  for (const point of points) {
    minX = Math.min(minX, point.px); minY = Math.min(minY, point.py);
    maxX = Math.max(maxX, point.px); maxY = Math.max(maxY, point.py);
  }
  if (!Number.isFinite(minX)) { minX = minY = maxX = maxY = 0; }
  return { minX: minX - padding, minY: minY - padding, width: maxX - minX + padding * 2, height: maxY - minY + padding * 2 };
};
type CachedPoint = GraphPoint & { binding: string };
export type GraphLayoutCache = {
  positions: Map<string, CachedPoint>;
  endpointSlots: Map<string, number>;
  backboneSlots: Map<string, number>;
  nextComponent: number;
};
export const createGraphLayoutCache = (): GraphLayoutCache => ({
  positions: new Map(), endpointSlots: new Map(), backboneSlots: new Map(), nextComponent: 0,
});

export const graphAdjacency = (nodes: LayoutNode[], edges: NetEdge[]) => {
  const adjacency = new Map(nodes.map((node) => [node.address, new Set<string>()]));
  for (const edge of edges) {
    if (edge.from !== edge.to && adjacency.has(edge.from) && adjacency.has(edge.to)) {
      adjacency.get(edge.from).add(edge.to);
      adjacency.get(edge.to).add(edge.from);
    }
  }
  return adjacency;
};

export const graphNeighborhood = (adjacency: Map<string, Set<string>>, start: string, depth: number) => {
  const found = new Set<string>();
  if (!adjacency.has(start)) { return found; }
  found.add(start);
  let frontier = [start];
  for (let step = 0; step < depth && frontier.length; step++) {
    const next: string[] = [];
    for (const address of frontier) {
      for (const neighbor of adjacency.get(address) ?? []) {
        if (!found.has(neighbor)) { found.add(neighbor); next.push(neighbor); }
      }
    }
    frontier = next;
  }
  return found;
};

export const graphPath = (adjacency: Map<string, Set<string>>, from: string, to: string): string[] => {
  if (!adjacency.has(from) || !adjacency.has(to)) { return []; }
  const parents = new Map<string, string | null>([[from, null]]);
  const queue = [from];
  for (let index = 0; index < queue.length; index++) {
    const address = queue[index];
    if (address === to) {
      const path: string[] = [];
      for (let cursor: string | null = to; cursor !== null; cursor = parents.get(cursor)) { path.push(cursor); }
      return path.reverse();
    }
    for (const neighbor of adjacency.get(address) ?? []) {
      if (!parents.has(neighbor)) { parents.set(neighbor, address); queue.push(neighbor); }
    }
  }
  return [];
};

const GAP = 76;

/** Pinned backbone lanes and endpoint slots under their actual APC.
 * Revealing a slice allocates only missing vertices. Rebinding an endpoint
 * moves that endpoint while leaving unrelated cached positions untouched.
 */
export const layoutGraph = (nodes: LayoutNode[], edges: NetEdge[], cache: GraphLayoutCache) => {
  const byAddress = new Map(nodes.map((node) => [node.address, node]));
  const adjacency = graphAdjacency(nodes, edges);
  const backbone = new Set(nodes.filter((node) => ['apc', 'gateway', 'relay'].includes(node.type)).map((node) => node.address));
  const parents = new Map<string, string>();
  for (const node of nodes) {
    if (node.uplink && !backbone.has(node.address)) { parents.set(node.address, node.uplink); }
  }
  for (const edge of edges) {
    if (!byAddress.has(edge.from) || !byAddress.has(edge.to)) { continue; }
    // Edge endpoints are canonicalized by address, not directed child -> APC.
    // The authoritative binding may also point outside the current graph slice.
    if (edge.kind === 'endpoint') {
      const from = byAddress.get(edge.from);
      const to = byAddress.get(edge.to);
      if (from.type === 'apc' && !backbone.has(to.address) && !parents.has(to.address)) { parents.set(to.address, from.address); }
      if (to.type === 'apc' && !backbone.has(from.address) && !parents.has(from.address)) { parents.set(from.address, to.address); }
    }
    else { backbone.add(edge.from); backbone.add(edge.to); }
  }
  const binding = (node: LayoutNode) => {
    if (backbone.has(node.address)) { return 'backbone'; }
    const parent = parents.get(node.address) ?? node.uplink ?? '';
    const anchor = cache.positions.get(parent);
    return `endpoint:${parent}:${anchor ? `${anchor.px},${anchor.py}` : 'unresolved'}`;
  };
  const result = () => new Map(nodes.map((node) => [node.address, cache.positions.get(node.address)]));
  if (nodes.every((node) => cache.positions.get(node.address)?.binding === binding(node))) { return result(); }

  const buckets = new Map<string, GraphPoint[]>();
  const cell = (x: number, y: number) => `${Math.floor(x / GAP)},${Math.floor(y / GAP)}`;
  const insert = (point: GraphPoint) => {
    const key = cell(point.px, point.py);
    const bucket = buckets.get(key);
    if (bucket) { bucket.push(point); } else { buckets.set(key, [point]); }
  };
  const free = (point: GraphPoint) => {
    const cx = Math.floor(point.px / GAP);
    const cy = Math.floor(point.py / GAP);
    for (let dx = -1; dx <= 1; dx++) {
      for (let dy = -1; dy <= 1; dy++) {
        for (const other of buckets.get(`${cx + dx},${cy + dy}`) ?? []) {
          if (Math.abs(point.px - other.px) < GAP && Math.abs(point.py - other.py) < GAP) { return false; }
        }
      }
    }
    return true;
  };
  for (const point of cache.positions.values()) { insert(point); }
  const save = (address: string, point: GraphPoint, signature: string) => {
    cache.positions.set(address, { ...point, binding: signature });
    insert(point);
  };
  const componentOrigin = () => {
    let point: GraphPoint;
    do {
      const slot = cache.nextComponent++;
      point = { px: 1000 + (slot % 3) * 1280, py: 600 + Math.floor(slot / 3) * 1280 };
    } while (!free(point));
    return point;
  };
  const backboneSlot = (anchor: GraphPoint, owner: string) => {
    let slot = cache.backboneSlots.get(owner) ?? 0;
    let point: GraphPoint;
    do {
      const column = Math.floor(slot / 5) + 1;
      const row = [0, -1, 1, -2, 2][slot % 5];
      point = { px: anchor.px + column * 320, py: anchor.py + row * 320 };
      slot++;
    } while (!free(point));
    cache.backboneSlots.set(owner, slot);
    return point;
  };

  const ordered = [...backbone].sort();
  const pending = new Set(ordered.filter((address) => cache.positions.get(address)?.binding !== 'backbone'));
  const queue: string[] = [];
  for (const address of ordered) {
    if (!pending.has(address)) { queue.push(...[...(adjacency.get(address) ?? [])].filter((neighbor) => pending.has(neighbor)).sort()); }
  }
  let cursor = 0;
  let root = 0;
  while (pending.size) {
    let address: string | undefined;
    while (cursor < queue.length && !address) {
      const next = queue[cursor++];
      if (pending.has(next)) { address = next; }
    }
    if (!address) {
      while (!pending.has(ordered[root])) { root++; }
      address = ordered[root];
    }
    pending.delete(address);
    const neighbors = [...(adjacency.get(address) ?? [])].filter((neighbor) => backbone.has(neighbor) && !pending.has(neighbor) && cache.positions.has(neighbor)).sort();
    const anchorAddress = neighbors[0];
    const anchor = cache.positions.get(anchorAddress);
    save(address, anchor ? backboneSlot(anchor, anchorAddress) : componentOrigin(), 'backbone');
    queue.push(...[...(adjacency.get(address) ?? [])].filter((neighbor) => pending.has(neighbor)).sort());
  }
  for (const node of [...nodes].sort((a, b) => a.address.localeCompare(b.address))) {
    if (backbone.has(node.address)) { continue; }
    const signature = binding(node);
    if (cache.positions.get(node.address)?.binding === signature) { continue; }
    const parent = parents.get(node.address) ?? node.uplink ?? '';
    const anchor = cache.positions.get(parent);
    if (!anchor) { save(node.address, componentOrigin(), signature); continue; }
    let slot = cache.endpointSlots.get(parent) ?? 0;
    let point: GraphPoint;
    do {
      const row = Math.ceil(Math.sqrt(slot + 2) - 1);
      const column = slot - (row * row - 1) - row;
      point = { px: anchor.px + column * 96, py: anchor.py + row * 96 };
      slot++;
    } while (!free(point));
    cache.endpointSlots.set(parent, slot);
    save(node.address, point, signature);
  }
  return result();
};
