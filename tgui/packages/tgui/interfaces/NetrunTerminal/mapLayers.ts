import type { PlacedNode } from './graphScene';
import { createGraphLayoutCache, GraphPoint, layoutGraph } from './mapLayout';
import { NetEdge, NetNode } from './types';

/** One layout and one node collection, with retained placements for every device. */
export class MapProjection {
  private readonly cache = createGraphLayoutCache();
  private sources = new Map<string, { source: NetNode; point: GraphPoint; placed: PlacedNode }>();
  private snapshot = { nodes: [] as PlacedNode[], edges: [] as NetEdge[] };

  update(nodes: NetNode[], edges: NetEdge[]) {
    const geometryChanged = nodes.length !== this.sources.size || nodes.some((node) => {
      const before = this.sources.get(node.address)?.source;
      return !before || before.x !== node.x || before.y !== node.y || before.z !== node.z;
    });
    const positions = geometryChanged ? layoutGraph(nodes, edges, this.cache) : this.cache.positions;
    const sources = new Map<string, { source: NetNode; point: GraphPoint; placed: PlacedNode }>();
    const placed = nodes.map((source) => {
      const point = positions.get(source.address), before = this.sources.get(source.address);
      const retained = before?.source === source && before.point === point
        ? before : { source, point, placed: { ...source, ...point } };
      sources.set(source.address, retained);
      return retained.placed;
    });
    this.sources = sources;
    const sameNodes = placed.length === this.snapshot.nodes.length && placed.every((node, i) => node === this.snapshot.nodes[i]);
    if (sameNodes && edges === this.snapshot.edges) { return this.snapshot; }
    this.snapshot = { nodes: sameNodes ? this.snapshot.nodes : placed, edges };
    return this.snapshot;
  }
}
