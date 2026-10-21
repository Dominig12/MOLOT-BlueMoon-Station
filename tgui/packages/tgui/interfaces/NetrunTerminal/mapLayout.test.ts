import { GRAPH_GAP, GRAPH_LEVEL } from './graphLayout';
import { createGraphLayoutCache, graphAdjacency, graphBounds, graphNeighborhood, graphPath, GraphPoint, layoutGraph } from './mapLayout';
import { NetEdge } from './types';

const nodes = [
  { address: 'APC-A', type: 'apc', uplink: null },
  { address: 'APC-B', type: 'apc', uplink: null },
  { address: 'RELAY', type: 'gateway', uplink: 'APC-B' },
  { address: 'CLIENT', type: 'terminal', uplink: 'APC-A' },
];
const edges: NetEdge[] = [
  { id: 'client', from: 'CLIENT', to: 'APC-A', kind: 'endpoint' },
  { id: 'chain', from: 'APC-A', to: 'APC-B', kind: 'apc' },
  { id: 'relay', from: 'RELAY', to: 'APC-B', kind: 'relay' },
];

/** Strict segment intersection, excluding links that legitimately share a tree node. */
const orient = (a: GraphPoint, b: GraphPoint, c: GraphPoint) =>
  Math.sign((b.py - a.py) * (c.px - b.px) - (b.px - a.px) * (c.py - b.py));
const segmentsCross = (p1: GraphPoint, p2: GraphPoint, p3: GraphPoint, p4: GraphPoint) => {
  const d1 = orient(p3, p4, p1), d2 = orient(p3, p4, p2), d3 = orient(p1, p2, p3), d4 = orient(p1, p2, p4);
  return d1 !== d2 && d3 !== d4 && d1 !== 0 && d2 !== 0 && d3 !== 0 && d4 !== 0;
};
const treeEdgeCrossings = (layout: Map<string, GraphPoint>, links: NetEdge[]) => {
  let crossings = 0;
  for (let i = 0; i < links.length; i++) {
    for (let j = i + 1; j < links.length; j++) {
      const a = links[i], b = links[j];
      if (a.from === b.from || a.from === b.to || a.to === b.from || a.to === b.to) { continue; }
      if (segmentsCross(layout.get(a.from), layout.get(a.to), layout.get(b.from), layout.get(b.to))) { crossings++; }
    }
  }
  return crossings;
};

describe('tidy-tree network graph layout', () => {
  test('topology controls placement without reading physical coordinates or input order', () => {
    const poisoned = nodes.map((node) => Object.defineProperties({ ...node }, {
      x: { get: () => { throw new Error('Tile x must not enter the layout'); } },
      y: { get: () => { throw new Error('Tile y must not enter the layout'); } },
      z: { get: () => { throw new Error('Tile z must not enter the layout'); } },
    }));
    expect(layoutGraph(poisoned, edges, createGraphLayoutCache()))
      .toEqual(layoutGraph(nodes, edges, createGraphLayoutCache()));
    expect(layoutGraph([...nodes].reverse(), [...edges].reverse(), createGraphLayoutCache()))
      .toEqual(layoutGraph(nodes, edges, createGraphLayoutCache()));
  });

  test('every node occupies a distinct cell', () => {
    const layout = layoutGraph(nodes, edges, createGraphLayoutCache());
    const cells = new Set([...layout.values()].map((point) => `${point.px},${point.py}`));
    expect(cells.size).toBe(nodes.length);
  });

  test('children always sit on a deeper level than their parent', () => {
    const layout = layoutGraph(nodes, edges, createGraphLayoutCache());
    expect(layout.get('CLIENT').py).toBeGreaterThan(layout.get('APC-A').py);
    expect(layout.get('RELAY').py).toBeGreaterThan(layout.get('APC-B').py);
  });

  test('a pure tree is laid out without a single edge crossing', () => {
    const treeNodes = [
      { address: 'ROOT', type: 'apc', uplink: null },
      { address: 'APC-1', type: 'apc', uplink: null },
      { address: 'APC-2', type: 'apc', uplink: null },
      { address: 'C1', type: 'camera', uplink: 'APC-1' },
      { address: 'C2', type: 'camera', uplink: 'APC-1' },
      { address: 'C3', type: 'camera', uplink: 'APC-2' },
      { address: 'DEEP', type: 'implant', uplink: 'C3' },
    ];
    const treeEdges: NetEdge[] = [
      { id: 'a1', from: 'APC-1', to: 'ROOT', kind: 'apc' },
      { id: 'a2', from: 'APC-2', to: 'ROOT', kind: 'apc' },
      { id: 'c1', from: 'C1', to: 'APC-1', kind: 'endpoint' },
      { id: 'c2', from: 'C2', to: 'APC-1', kind: 'endpoint' },
      { id: 'c3', from: 'C3', to: 'APC-2', kind: 'endpoint' },
      { id: 'deep', from: 'DEEP', to: 'C3', kind: 'endpoint' },
    ];
    const layout = layoutGraph(treeNodes, treeEdges, createGraphLayoutCache());
    expect(new Set([...layout.values()].map((p) => `${p.px},${p.py}`)).size).toBe(treeNodes.length);
    expect(treeEdgeCrossings(layout, treeEdges)).toBe(0);
  });

  test('rebinding an endpoint moves it one level beneath its new parent', () => {
    const before = layoutGraph(nodes, edges, createGraphLayoutCache());
    expect(before.get('CLIENT').py - before.get('APC-A').py).toBe(GRAPH_LEVEL);
    const reboundNodes = nodes.map((node) => node.address === 'CLIENT' ? { ...node, uplink: 'APC-B' } : node);
    const reboundEdges = edges.map((edge) => edge.id === 'client' ? { ...edge, to: 'APC-B' } : edge);
    const after = layoutGraph(reboundNodes, reboundEdges, createGraphLayoutCache());
    expect(after.get('CLIENT').py - after.get('APC-B').py).toBe(GRAPH_LEVEL);
  });

  test('a dense APC fanout keeps distinct, evenly spaced leaves without crossings', () => {
    const clients = Array.from({ length: 400 }, (_, index) => ({ address: `C${String(index).padStart(3, '0')}`, type: 'terminal', uplink: 'APC-A' }));
    const clientEdges: NetEdge[] = clients.map((node) => ({ id: node.address, from: node.address, to: 'APC-A', kind: 'endpoint' }));
    const layout = layoutGraph([nodes[0], ...clients], clientEdges, createGraphLayoutCache());
    expect(new Set([...layout.values()].map((p) => `${p.px},${p.py}`)).size).toBe(clients.length + 1);
    const leaves = clients.map((node) => layout.get(node.address).px).sort((a, b) => a - b);
    for (let i = 1; i < leaves.length; i++) { expect(leaves[i] - leaves[i - 1]).toBeGreaterThanOrEqual(GRAPH_GAP); }
    expect(treeEdgeCrossings(layout, clientEdges)).toBe(0);
  });

  test('malformed parent cycles still terminate with distinct finite positions', () => {
    const cyclic = Array.from({ length: 50 }, (_, i) => ({ address: `N${i}`, type: 'implant', uplink: `N${(i + 1) % 50}` }));
    const layout = layoutGraph(cyclic, [], createGraphLayoutCache());
    expect(layout.size).toBe(50);
    for (const point of layout.values()) { expect(Number.isFinite(point.px) && Number.isFinite(point.py)).toBe(true); }
    expect(new Set([...layout.values()].map((p) => `${p.px},${p.py}`)).size).toBe(50);
  });

  test('graph bounds contain negative and far-away coordinates without changing the world origin', () => {
    const points = [{ px: -1800, py: -900 }, { px: 16000, py: 4200 }];
    const bounds = graphBounds(points);
    expect(bounds.minX).toBeLessThan(points[0].px);
    expect(bounds.minY).toBeLessThan(points[0].py);
    expect(bounds.minX + bounds.width).toBeGreaterThan(points[1].px);
    expect(bounds.minY + bounds.height).toBeGreaterThan(points[1].py);
  });

  test('graph neighborhoods and paths contain only published edges', () => {
    const adjacency = graphAdjacency(nodes, edges);
    expect([...adjacency.get('CLIENT')]).toEqual(['APC-A']);
    expect(graphNeighborhood(adjacency, 'CLIENT', 2)).toEqual(new Set(['CLIENT', 'APC-A', 'APC-B']));
    expect(graphPath(adjacency, 'CLIENT', 'RELAY')).toEqual(['CLIENT', 'APC-A', 'APC-B', 'RELAY']);
    expect(graphPath(graphAdjacency(nodes, edges.slice(0, 1)), 'CLIENT', 'RELAY')).toEqual([]);
  });
});
