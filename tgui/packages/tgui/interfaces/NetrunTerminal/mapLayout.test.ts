import { createGraphLayoutCache, graphAdjacency, graphNeighborhood, graphPath, layoutGraph } from './mapLayout';
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

describe('incremental network graph layout', () => {
  test('topology controls placement without reading physical coordinates', () => {
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

  test('revealing and hiding graph slices preserves all previously placed vertices', () => {
    const cache = createGraphLayoutCache();
    const original = layoutGraph(nodes, edges, cache);
    const expanded = [...nodes, { address: 'APC-C', type: 'apc', uplink: null }, { address: 'NEW', type: 'camera', uplink: 'APC-A' }];
    const addedEdges: NetEdge[] = [...edges,
      { id: 'new-apc', from: 'APC-B', to: 'APC-C', kind: 'apc' },
      { id: 'new-client', from: 'NEW', to: 'APC-A', kind: 'endpoint' },
    ];
    const revealed = layoutGraph(expanded, addedEdges, cache);
    for (const node of nodes) { expect(revealed.get(node.address)).toEqual(original.get(node.address)); }
    layoutGraph(nodes.slice(0, 1), [], cache);
    const restored = layoutGraph(expanded, addedEdges, cache);
    expect(restored).toEqual(revealed);
    expect(layoutGraph(expanded, addedEdges, cache).get('NEW')).toBe(restored.get('NEW'));
  });

  test('rebinding moves only the endpoint to its explicit new APC', () => {
    const cache = createGraphLayoutCache();
    const before = layoutGraph(nodes, edges, cache);
    const rebound = edges.map((edge) => edge.id === 'client' ? { ...edge, to: 'APC-B' } : edge);
    // Explicit wiring takes precedence even if legacy uplink metadata is stale.
    const after = layoutGraph(nodes, rebound, cache);
    expect(after.get('CLIENT')).not.toEqual(before.get('CLIENT'));
    expect(after.get('CLIENT').binding).toContain('endpoint:APC-B:');
    for (const address of ['APC-A', 'APC-B', 'RELAY']) { expect(after.get(address)).toEqual(before.get(address)); }
    expect(after.get('CLIENT').py).toBeGreaterThan(after.get('APC-B').py);
  });

  test('graph neighborhoods and paths contain only published edges', () => {
    const adjacency = graphAdjacency(nodes, edges);
    expect([...adjacency.get('CLIENT')]).toEqual(['APC-A']);
    expect(graphNeighborhood(adjacency, 'CLIENT', 2)).toEqual(new Set(['CLIENT', 'APC-A', 'APC-B']));
    expect(graphPath(adjacency, 'CLIENT', 'RELAY')).toEqual(['CLIENT', 'APC-A', 'APC-B', 'RELAY']);
    expect(graphPath(graphAdjacency(nodes, edges.slice(0, 1)), 'CLIENT', 'RELAY')).toEqual([]);
  });

  test('a dense APC fanout has distinct slots with local collision separation', () => {
    const clients = Array.from({ length: 1000 }, (_, index) => ({ address: `C${index}`, type: 'terminal', uplink: 'APC-A' }));
    const clientEdges: NetEdge[] = clients.map((node) => ({ id: node.address, from: node.address, to: 'APC-A', kind: 'endpoint' }));
    const layout = layoutGraph([nodes[0], ...clients], clientEdges, createGraphLayoutCache());
    const buckets = new Map<string, { px: number; py: number }[]>();
    for (const point of layout.values()) {
      const cx = Math.floor(point.px / 76);
      const cy = Math.floor(point.py / 76);
      for (let dx = -1; dx <= 1; dx++) {
        for (let dy = -1; dy <= 1; dy++) {
          for (const other of buckets.get(`${cx + dx},${cy + dy}`) ?? []) {
            expect(Math.max(Math.abs(point.px - other.px), Math.abs(point.py - other.py))).toBeGreaterThanOrEqual(76);
          }
        }
      }
      const key = `${cx},${cy}`;
      buckets.set(key, [...(buckets.get(key) ?? []), point]);
    }
    expect(layout.size).toBe(1001);
  });
});
