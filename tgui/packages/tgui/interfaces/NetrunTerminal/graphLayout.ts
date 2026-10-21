import type { GraphPoint, LayoutNode } from './mapLayout';
import { NetEdge } from './types';

/** Kept for call-site compatibility; the tidy layout is deterministic and holds no state. */
export type GraphLayoutCache = Record<string, never>;
export const createGraphLayoutCache = (): GraphLayoutCache => ({});

export const graphAdjacency = (nodes: LayoutNode[], edges: NetEdge[]) => {
  const adjacency = new Map(nodes.map((node) => [node.address, new Set<string>()]));
  for (const edge of edges) {
    if (edge.from !== edge.to && adjacency.has(edge.from) && adjacency.has(edge.to)) {
      adjacency.get(edge.from).add(edge.to); adjacency.get(edge.to).add(edge.from);
    }
  }
  return adjacency;
};

/** Horizontal distance between adjacent leaves. */
export const GRAPH_GAP = 128;
/** Vertical distance between tree levels. */
export const GRAPH_LEVEL = Math.round(GRAPH_GAP * 1.6);
/** Shape, stroke, status badges and rings all remain inside this world-space radius. */
export const GRAPH_GLYPH_RADIUS = 24;

/**
 * Layered tidy-tree placement (a leaf-slot variant of Reingold–Tilford).
 *
 * The permitted graph is a forest: every endpoint has one uplink parent, and the
 * APC/relay backbone forms a spanning tree. Laying each tree out by levels — leaves
 * on their own columns left to right, every parent centred over its contiguous block
 * of children — guarantees that no two tree edges cross and no two nodes share a cell.
 * The few extra inter-sector relay links are not tree edges and still render as drawn.
 */
export class GraphLayout {
  constructor(readonly cache: GraphLayoutCache = createGraphLayoutCache()) {}

  /** A deterministic layout keeps no retained geometry; re-arrange simply recomputes. */
  clear() {}

  update(nodes: LayoutNode[], edges: NetEdge[]): Map<string, GraphPoint> {
    const byAddress = new Map(nodes.map((node) => [node.address, node]));
    const addresses = [...byAddress.keys()].sort();
    const backbone = new Set(nodes.filter((node) => ['apc', 'gateway', 'relay'].includes(node.type)).map((node) => node.address));
    for (const edge of edges) {
      if (edge.kind !== 'endpoint' && byAddress.has(edge.from) && byAddress.has(edge.to)) {
        backbone.add(edge.from); backbone.add(edge.to);
      }
    }

    // Parent assignment. Endpoints follow their authoritative uplink, then any endpoint
    // edge to the backbone; the backbone is spanned by a deterministic BFS.
    const parent = new Map<string, string>();
    for (const node of nodes) {
      if (!backbone.has(node.address) && node.uplink && byAddress.has(node.uplink) && node.uplink !== node.address) {
        parent.set(node.address, node.uplink);
      }
    }
    for (const edge of [...edges].sort((a, b) => a.id.localeCompare(b.id))) {
      if (edge.kind !== 'endpoint') { continue; }
      for (const [child, par] of [[edge.from, edge.to], [edge.to, edge.from]]) {
        if (byAddress.has(child) && !backbone.has(child) && !parent.has(child) && backbone.has(par)) {
          parent.set(child, par);
        }
      }
    }
    const backboneAdjacency = new Map<string, string[]>();
    for (const address of backbone) { backboneAdjacency.set(address, []); }
    for (const edge of edges) {
      if (edge.kind === 'endpoint' || edge.from === edge.to) { continue; }
      if (backbone.has(edge.from) && backbone.has(edge.to)) {
        backboneAdjacency.get(edge.from).push(edge.to); backboneAdjacency.get(edge.to).push(edge.from);
      }
    }
    const spanned = new Set<string>();
    for (const root of [...backbone].sort()) {
      if (spanned.has(root)) { continue; }
      spanned.add(root);
      const queue = [root];
      for (let i = 0; i < queue.length; i++) {
        for (const neighbor of [...(backboneAdjacency.get(queue[i]) || [])].sort()) {
          if (!spanned.has(neighbor)) { spanned.add(neighbor); parent.set(neighbor, queue[i]); queue.push(neighbor); }
        }
      }
    }
    // Break malformed parent cycles so the forest is always acyclic.
    for (const address of addresses) {
      const seen = new Set<string>();
      let cursor: string | undefined = address;
      while (cursor && parent.has(cursor)) {
        if (seen.has(cursor)) { parent.delete(cursor); break; }
        seen.add(cursor); cursor = parent.get(cursor);
      }
    }

    const children = new Map<string, string[]>();
    const roots: string[] = [];
    for (const address of addresses) {
      const par = parent.get(address);
      if (par && byAddress.has(par)) {
        const list = children.get(par) || [];
        list.push(address); children.set(par, list);
      } else {
        roots.push(address);
      }
    }
    for (const list of children.values()) { list.sort(); }
    roots.sort();

    // Iterative post-order: leaves claim successive columns, parents centre over children.
    const px = new Map<string, number>();
    const depth = new Map<string, number>();
    let column = 0;
    for (const root of roots) {
      const stack: { address: string; level: number; index: number }[] = [{ address: root, level: 0, index: 0 }];
      while (stack.length) {
        const frame = stack[stack.length - 1];
        if (frame.index === 0) { depth.set(frame.address, frame.level); }
        const kids = children.get(frame.address) || [];
        if (frame.index < kids.length) {
          stack.push({ address: kids[frame.index++], level: frame.level + 1, index: 0 });
          continue;
        }
        if (!kids.length) { px.set(frame.address, column++ * GRAPH_GAP); }
        else {
          let sum = 0;
          for (const kid of kids) { sum += px.get(kid); }
          px.set(frame.address, sum / kids.length);
        }
        stack.pop();
      }
      column += 1; // keep a clear gap between separate trees
    }

    return new Map(addresses.map((address) => [address, { px: px.get(address) ?? 0, py: (depth.get(address) ?? 0) * GRAPH_LEVEL }]));
  }
}
