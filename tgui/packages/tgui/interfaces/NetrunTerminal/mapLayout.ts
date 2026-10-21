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

const GAP = 78;
const GOLDEN_ANGLE = Math.PI * (3 - Math.sqrt(5));

/**
 * Stable, incremental placement of a topology received from the DM backend.
 * No station tile coordinates and no time-dependent simulation are involved.
 *
 * Re-parenting an endpoint invalidates its placement AND the placement of all
 * visible descendants; unaffected nodes keep their exact point objects.
 * A spatial hash keeps collision checks local even for thousands of clients.
 */
export const layoutGraph = (nodes: LayoutNode[], edges: NetEdge[], cache: GraphLayoutCache) => {
  const byAddress = new Map(nodes.map((node) => [node.address, node]));
  const adjacency = graphAdjacency(nodes, edges);
  const backbone = new Set(nodes.filter((node) => ['apc', 'gateway', 'relay'].includes(node.type)).map((n) => n.address));
  for (const edge of edges) {
    if (edge.kind !== 'endpoint' && byAddress.has(edge.from) && byAddress.has(edge.to)) {
      backbone.add(edge.from); backbone.add(edge.to);
    }
  }
  const parents = new Map<string, string>();
  for (const node of nodes) {
    if (!backbone.has(node.address) && node.uplink && node.uplink !== node.address) {
      parents.set(node.address, node.uplink);
    }
  }
  for (const edge of edges) {
    if (edge.kind !== 'endpoint') { continue; }
    const first = byAddress.get(edge.from), second = byAddress.get(edge.to);
    if (!first || !second) { continue; }
    if (backbone.has(first.address) && !backbone.has(second.address) && !parents.has(second.address)) {
      parents.set(second.address, first.address);
    } else if (backbone.has(second.address) && !backbone.has(first.address) && !parents.has(first.address)) {
      parents.set(first.address, second.address);
    }
  }
  const addresses = [...byAddress.keys()].sort();
  const buckets = new Map<string, GraphPoint[]>();
  const key = (point: GraphPoint) => `${Math.floor(point.px / GAP)},${Math.floor(point.py / GAP)}`;
  const occupy = (point: GraphPoint) => {
    const id = key(point);
    const list = buckets.get(id);
    if (list) { list.push(point); } else { buckets.set(id, [point]); }
  };
  const free = (px: number, py: number) => {
    const cx = Math.floor(px / GAP), cy = Math.floor(py / GAP);
    for (let dx = -1; dx <= 1; dx++) {
      for (let dy = -1; dy <= 1; dy++) {
        for (const other of buckets.get(`${cx + dx},${cy + dy}`) ?? []) {
          if (Math.abs(px - other.px) < GAP && Math.abs(py - other.py) < GAP) { return false; }
        }
      }
    }
    return true;
  };
  const newPoints = new Map<string, CachedPoint>();
  const status = new Map<string, boolean>();
  const inProgress = new Set<string>();
  // A cached endpoint is stable only if every ancestor and its binding remain stable.
  // This prepass means old positions of a moved branch cannot obstruct its new home.
  const isStable = (address: string): boolean => {
    if (status.has(address)) { return status.get(address); }
    const node = byAddress.get(address), point = cache.positions.get(address);
    if (!node || !point || inProgress.has(address)) { status.set(address, false); return false; }
    if (backbone.has(address)) {
      const stable = point.binding === 'backbone'; status.set(address, stable); return stable;
    }
    inProgress.add(address);
    const parent = parents.get(address) || '';
    const ancestor = byAddress.has(parent) ? isStable(parent) : !!cache.positions.get(parent);
    const anchor = cache.positions.get(parent);
    const signature = `endpoint:${parent}:${anchor ? `${anchor.px},${anchor.py}` : 'unresolved'}`;
    const stable = ancestor && point.binding === signature;
    inProgress.delete(address); status.set(address, stable);
    return stable;
  };
  for (const address of addresses) { isStable(address); }
  // Retain positions of hidden vertices so exposing a graph slice never
  // causes an existing endpoint to appear inside a previously hidden node.
  for (const [address, point] of cache.positions) {
    if (!byAddress.has(address) || status.get(address)) { occupy(point); }
  }
  const save = (address: string, px: number, py: number, binding: string) => {
    const point = { px, py, binding };
    newPoints.set(address, point);
    cache.positions.set(address, point);
    occupy(point);
    return point;
  };
  const origin = (address: string) => {
    let px = 0, py = 0;
    while (true) {
      const slot = cache.nextComponent++;
      // Square spiral of disconnected components; not a giant straight row.
      const ring = Math.ceil(Math.sqrt(slot + 1));
      const angle = slot * GOLDEN_ANGLE;
      px = Math.round(950 + Math.cos(angle) * ring * 620);
      py = Math.round(600 + Math.sin(angle) * ring * 620);
      if (free(px, py)) { return save(address, px, py, 'backbone'); }
    }
  };
  const placed = new Map<string, CachedPoint>();
  const placeBackbone = (address: string) => {
    const existing = cache.positions.get(address);
    if (status.get(address) && existing) { placed.set(address, existing); return; }
    const neighbors = [...(adjacency.get(address) || [])]
      .filter((other) => backbone.has(other) && placed.has(other)).sort();
    const owner = neighbors[0];
    const anchor = owner && placed.get(owner);
    if (!anchor) { placed.set(address, origin(address)); return; }
    let slot = cache.backboneSlots.get(owner) || 0;
    while (true) {
      const ring = Math.floor(slot / 8) + 1;
      const angle = ((slot % 8) / 8) * Math.PI * 2;
      const px = anchor.px + Math.round(Math.cos(angle) * 320 * ring);
      const py = anchor.py + Math.round(Math.sin(angle) * 320 * ring);
      slot++;
      if (!free(px, py)) { continue; }
      cache.backboneSlots.set(owner, slot);
      placed.set(address, save(address, px, py, 'backbone'));
      return;
    }
  };
  const backboneAddresses = addresses.filter((address) => backbone.has(address));
  // Place existing components first, then traverse their neighborhood.
  const queue: string[] = backboneAddresses.filter((address) => status.get(address));
  for (const address of queue) { placeBackbone(address); }
  const pending = new Set(backboneAddresses.filter((address) => !status.get(address)));
  let cursor = 0;
  while (pending.size) {
    let next: string | undefined;
    while (cursor < queue.length && !next) {
      const anchor = queue[cursor++];
      next = [...(adjacency.get(anchor) || [])].filter((address) => pending.has(address)).sort()[0];
      if (next) { break; }
    }
    if (!next) { next = [...pending].sort()[0]; }
    placeBackbone(next); pending.delete(next); queue.push(next);
  }
  const placing = new Set<string>();
  const placeEndpoint = (address: string): CachedPoint => {
    const known = placed.get(address);
    if (known) { return known; }
    const cached = cache.positions.get(address);
    if (status.get(address) && cached) { placed.set(address, cached); return cached; }
    // Guard malicious/broken cyclic uplinks (DM normally emits a tree here).
    if (placing.has(address)) {
      const px = 950 + cache.nextComponent++ * 300;
      const point = save(address, px, 900, 'endpoint::unresolved');
      placed.set(address, point); return point;
    }
    placing.add(address);
    const parent = parents.get(address) || '';
    const anchor = byAddress.has(parent)
      ? (backbone.has(parent) ? placed.get(parent) : placeEndpoint(parent))
      : cache.positions.get(parent);
    const signature = `endpoint:${parent}:${anchor ? `${anchor.px},${anchor.py}` : 'unresolved'}`;
    if (!anchor) {
      // No visible/cached parent: keep deterministic disconnected placement.
      let slot = cache.nextComponent++;
      let point: CachedPoint;
      do {
        const px = 950 + (slot % 10) * 180;
        const py = 900 + Math.floor(slot / 10) * 180;
        if (free(px, py)) { point = save(address, px, py, signature); break; }
        slot++;
      } while (true);
      placing.delete(address); placed.set(address, point); return point;
    }
    let slot = cache.endpointSlots.get(parent) || 0;
    let point: CachedPoint;
    while (true) {
      // Golden-angle sunflower: natural branching, nearly uniform density.
      // Slot zero is directly below its parent for an intuitive first child.
      const angle = Math.PI / 2 + slot * GOLDEN_ANGLE;
      const distance = 115 * Math.sqrt(slot + 1);
      const px = anchor.px + Math.round(Math.cos(angle) * distance);
      const py = anchor.py + Math.round(Math.sin(angle) * distance);
      slot++;
      if (free(px, py)) { point = save(address, px, py, signature); break; }
    }
    cache.endpointSlots.set(parent, slot);
    placing.delete(address); placed.set(address, point);
    return point;
  };
  for (const address of addresses) {
    if (!backbone.has(address)) { placeEndpoint(address); }
  }
  // Hidden slice points remain available for stability, but don't retain
  // deleted addresses forever on servers creating thousands of ephemeral nodes.
  if (cache.positions.size > 30000) {
    for (const address of cache.positions.keys()) {
      if (!byAddress.has(address)) { cache.positions.delete(address); }
    }
    for (const address of cache.endpointSlots.keys()) {
      if (!cache.positions.has(address)) { cache.endpointSlots.delete(address); }
    }
    for (const address of cache.backboneSlots.keys()) {
      if (!cache.positions.has(address)) { cache.backboneSlots.delete(address); }
    }
  }
  return new Map(addresses.map((address) => [address, placed.get(address)]));
};
