import type { GraphPoint, LayoutNode } from './mapLayout';
import { NetEdge } from './types';

type CachedPoint = GraphPoint & { binding: string };
export type GraphLayoutCache = {
  positions: Map<string, CachedPoint>;
  endpointSlots: Map<string, number>;
  backboneSlots: Map<string, number>;
  released: Map<string, GraphPoint>;
  parents: Map<string, string>;
};
export const createGraphLayoutCache = (): GraphLayoutCache => ({
  positions: new Map(), endpointSlots: new Map(), backboneSlots: new Map(), released: new Map(), parents: new Map(),
});
export const graphAdjacency = (nodes: LayoutNode[], edges: NetEdge[]) => {
  const adjacency = new Map(nodes.map((node) => [node.address, new Set<string>()]));
  for (const edge of edges) {
    if (edge.from !== edge.to && adjacency.has(edge.from) && adjacency.has(edge.to)) {
      adjacency.get(edge.from).add(edge.to); adjacency.get(edge.to).add(edge.from);
    }
  }
  return adjacency;
};

export const GRAPH_GAP = 96;
/** Shape, stroke, status badges and rings all remain inside this world-space radius. */
export const GRAPH_GLYPH_RADIUS = 24;
const key = (p: GraphPoint) => `${p.px},${p.py}`;

const spiral = (slot: number, spacing: number): GraphPoint => {
  const r = Math.ceil((Math.sqrt(slot + 2) - 1) / 2);
  const t = (slot - ((2 * r - 1) ** 2 - 1) + r) % (8 * r);
  let x: number, y: number;
  if (t < 2 * r) { x = -r + t; y = r; }
  else if (t < 4 * r) { x = r; y = 3 * r - t; }
  else if (t < 6 * r) { x = 5 * r - t; y = -r; }
  else { x = -r; y = t - 7 * r; }
  return { px: x * spacing, py: y * spacing };
};

/** Stable lattice placement of the complete permitted graph, before local filtering. */
export class GraphLayout {
  constructor(readonly cache = createGraphLayoutCache()) {}

  clear() { Object.assign(this.cache, createGraphLayoutCache()); }

  update(nodes: LayoutNode[], edges: NetEdge[]) {
    const cache = this.cache;
    const byAddress = new Map(nodes.map((node) => [node.address, node]));
    const addresses = [...byAddress.keys()].sort();
    const adjacency = graphAdjacency(nodes, edges);
    const backbone = new Set(nodes.filter((node) => ['apc', 'gateway', 'relay'].includes(node.type)).map((node) => node.address));
    for (const edge of edges) {
      if (edge.kind !== 'endpoint' && byAddress.has(edge.from) && byAddress.has(edge.to)) {
        backbone.add(edge.from); backbone.add(edge.to);
      }
    }
    const parents = new Map<string, string>();
    for (const node of nodes) {
      if (!backbone.has(node.address) && node.uplink && byAddress.has(node.uplink) && node.uplink !== node.address) {
        parents.set(node.address, node.uplink);
      }
    }
    for (const edge of [...edges].sort((a, b) => a.id.localeCompare(b.id))) {
      if (edge.kind !== 'endpoint') { continue; }
      for (const [child, parent] of [[edge.from, edge.to], [edge.to, edge.from]]) {
        if (byAddress.has(child) && !byAddress.get(child).uplink && !backbone.has(child) && backbone.has(parent) && !parents.has(child)) {
          parents.set(child, parent);
        }
      }
    }
    // Break malformed cycles in layout only; all published real edges still render.
    const checked = new Set<string>();
    for (const address of addresses) {
      const path: string[] = [], seen = new Map<string, number>();
      let cursor = address;
      while (cursor && !checked.has(cursor)) {
        if (seen.has(cursor)) { parents.delete(path.slice(seen.get(cursor)).sort()[0]); break; }
        seen.set(cursor, path.length); path.push(cursor); cursor = parents.get(cursor);
      }
      for (const member of path) { checked.add(member); }
    }
    const old = new Map(cache.positions), stable = new Set<string>();
    const order: string[] = [], children = new Map<string, string[]>();
    for (const address of addresses) {
      const parent = parents.get(address);
      if (!parent || backbone.has(address)) { order.push(address); }
      else { const list = children.get(parent) || []; list.push(address); children.set(parent, list); }
    }
    for (let i = 0; i < order.length; i++) { order.push(...(children.get(order[i]) || [])); }
    const subtreeSizes = new Map(addresses.map((address) => [address, 1]));
    for (const address of [...order].reverse()) {
      const parent = parents.get(address);
      if (parent) { subtreeSizes.set(parent, subtreeSizes.get(parent) + subtreeSizes.get(address)); }
    }
    const largestBranch = Math.max(1, ...[...backbone].map((address) => subtreeSizes.get(address)));
    const backboneSpacing = Math.max(4, Math.ceil(Math.sqrt(largestBranch)) + 2) * GRAPH_GAP;
    const binding = (address: string, points: typeof cache.positions) => {
      const parent = parents.get(address), anchor = points.get(parent);
      return backbone.has(address) ? 'backbone' : `endpoint:${parent || ''}:${anchor ? `${anchor.px},${anchor.py}` : 'unresolved'}`;
    };
    for (const address of order) {
      const parent = parents.get(address);
      if (old.get(address)?.binding === binding(address, old) && (!parent || stable.has(parent))) { stable.add(address); }
    }
    const occupied = new Set<string>(), placed: typeof cache.positions = new Map();
    const invalidated = [...old.keys()].some((address) => !stable.has(address));
    for (const [address, point] of old) {
      if (stable.has(address)) { occupied.add(key(point)); placed.set(address, point); }
      else { cache.released.set(key(point), point); cache.positions.delete(address); }
    }
    const save = (address: string, point: GraphPoint) => {
      const cached = { ...point, binding: binding(address, placed) };
      occupied.add(key(point)); cache.released.delete(key(point));
      placed.set(address, cached); cache.positions.set(address, cached);
    };
    const findFree = (anchor: GraphPoint, owner: string, infrastructure = false) => {
      const slots = infrastructure ? cache.backboneSlots : cache.endpointSlots;
      const spacing = infrastructure ? backboneSpacing : GRAPH_GAP;
      const slotKey = `${owner}:${anchor.px},${anchor.py}`;
      let slot = slots.get(slotKey) || 0;
      let candidate: GraphPoint;
      do { const offset = spiral(slot++, spacing); candidate = { px: anchor.px + offset.px, py: anchor.py + offset.py }; }
      while (occupied.has(key(candidate)));
      if (infrastructure) {
        // Reserve enough room for each LAN's endpoint fanout and avoid a long vertical backbone.
        const candidates = [candidate];
        while (candidates.length < 8) {
          const offset = spiral(slot++, spacing), point = { px: anchor.px + offset.px, py: anchor.py + offset.py };
          if (!occupied.has(key(point))) { candidates.push(point); }
        }
        const bounds = [...placed.values()];
        const minX = Math.min(anchor.px, ...bounds.map((point) => point.px));
        const maxX = Math.max(anchor.px, ...bounds.map((point) => point.px));
        const minY = Math.min(anchor.py, ...bounds.map((point) => point.py));
        const maxY = Math.max(anchor.py, ...bounds.map((point) => point.py));
        const extent = (point: GraphPoint) => Math.max(Math.max(maxX, point.px) - Math.min(minX, point.px), Math.max(maxY, point.py) - Math.min(minY, point.py));
        candidates.sort((a, b) => extent(a) - extent(b));
        candidate = candidates[0];
        slot = 0;
      }
      const distance = (point: GraphPoint) => (point.px - anchor.px) ** 2 + (point.py - anchor.py) ** 2;
      let best = candidate;
      for (const point of cache.released.values()) {
        if (!occupied.has(key(point)) && distance(point) < distance(best)) { best = point; }
      }
      slots.set(slotKey, best === candidate ? slot : slot - 1);
      return best;
    };
    const placeRoot = (address: string) => {
      if (placed.has(address)) { return; }
      const owner = [...(adjacency.get(address) || [])].filter((neighbor) => backbone.has(neighbor) && placed.has(neighbor)).sort()[0];
      if (owner) { save(address, findFree(placed.get(owner), owner, true)); return; }
      if (!occupied.has('0,0')) { save(address, { px: 0, py: 0 }); return; }
      save(address, findFree({ px: 0, py: 0 }, 'components', true));
    };
    const queue = addresses.filter((address) => backbone.has(address) && placed.has(address));
    const pending = new Set(addresses.filter((address) => backbone.has(address) && !placed.has(address)));
    let cursor = 0;
    while (pending.size) {
      if (cursor >= queue.length) { const root = [...pending].sort()[0]; placeRoot(root); pending.delete(root); queue.push(root); }
      for (const neighbor of [...(adjacency.get(queue[cursor++]) || [])].sort()) {
        if (pending.delete(neighbor)) { placeRoot(neighbor); queue.push(neighbor); }
      }
    }
    for (const address of order) {
      if (placed.has(address)) { continue; }
      const parent = parents.get(address), anchor = placed.get(parent);
      if (old.has(address) && cache.parents.get(address) !== parent && !backbone.has(address)) {
        const branch = [address];
        for (let i = 0; i < branch.length; i++) {
          for (const child of children.get(branch[i]) || []) {
            if (old.has(child) && cache.parents.get(child) === parents.get(child)) { branch.push(child); }
          }
        }
        const previousRoot = old.get(address), origin = anchor || previousRoot;
        let slot = 0, target: GraphPoint;
        while (true) {
          const offset = !anchor && slot === 0 ? { px: 0, py: 0 } : spiral(slot - (anchor ? 0 : 1), GRAPH_GAP);
          slot++;
          target = { px: origin.px + offset.px, py: origin.py + offset.py };
          if (branch.every((member) => {
            const previous = old.get(member);
            return !occupied.has(key({ px: target.px + previous.px - previousRoot.px, py: target.py + previous.py - previousRoot.py }));
          })) { break; }
        }
        for (const member of branch) {
          const previous = old.get(member);
          save(member, { px: target.px + previous.px - previousRoot.px, py: target.py + previous.py - previousRoot.py });
        }
        continue;
      }
      if (!anchor) { placeRoot(address); continue; }
      const previous = old.get(address), previousAnchor = old.get(parent);
      const translated = previous && previousAnchor && previous.binding.startsWith(`endpoint:${parent}:`)
        ? { px: anchor.px + previous.px - previousAnchor.px, py: anchor.py + previous.py - previousAnchor.py } : null;
      save(address, translated && !occupied.has(key(translated)) ? translated : findFree(anchor, parent));
    }
    // Reuse holes on the next insertion without keeping deleted geometry or growing slot counters.
    if (invalidated) { cache.endpointSlots.clear(); cache.backboneSlots.clear(); }
    cache.released.clear();
    cache.parents = parents;
    return new Map(addresses.map((address) => [address, placed.get(address)]));
  }
}
