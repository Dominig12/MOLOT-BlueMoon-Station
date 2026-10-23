import { GraphEdgeIndex } from './graphEdgeIndex';
import { GRAPH_GAP, GRAPH_TILE } from './graphLayout';
import { graphAdjacency, GraphPoint } from './mapLayout';
import { ApcZone, NetEdge, NetNode } from './types';

export type PlacedNode = NetNode & GraphPoint;
const cellKey = (x: number, y: number) => `${x},${y}`;

/** Retained render scene with a separate spatial index; it never requests hidden nodes. */
export class GraphScene {
  nodes: PlacedNode[] = [];
  edges: NetEdge[] = [];
  byAddress = new Map<string, PlacedNode>();
  adjacency = new Map<string, Set<string>>();
  /** Cached incident edges let fast camera redraw inspect only on-screen connections. */
  incidentEdges = new Map<string, NetEdge[]>();
  private cells = new Map<string, PlacedNode[]>();
  private edgeIndex = new GraphEdgeIndex();

  update(nodes: PlacedNode[], edges: NetEdge[]) {
    this.nodes = nodes;
    this.edges = edges;
    this.byAddress = new Map(nodes.map((node) => [node.address, node]));
    this.adjacency = graphAdjacency(nodes, edges);
    this.edgeIndex.update(this.byAddress, edges);
    this.incidentEdges.clear();
    for (const edge of edges) {
      for (const address of [edge.from, edge.to]) {
        const incident = this.incidentEdges.get(address) || [];
        incident.push(edge);
        this.incidentEdges.set(address, incident);
      }
    }
    this.cells.clear();
    for (const node of nodes) {
      const key = cellKey(Math.floor(node.px / GRAPH_GAP), Math.floor(node.py / GRAPH_GAP));
      const cell = this.cells.get(key) || [];
      cell.push(node); this.cells.set(key, cell);
    }
  }

  /** Fit includes the selected APC's actual powered area, including empty tiles. */
  fitPoints(zones: ApcZone[] = []): GraphPoint[] {
    const points: GraphPoint[] = [...this.nodes];
    for (const zone of zones) {
      for (const run of zone.runs) {
        points.push({ px: (run.x - .5) * GRAPH_TILE, py: -(run.y + .5) * GRAPH_TILE },
          { px: (run.x + run.width - .5) * GRAPH_TILE, py: -(run.y - .5) * GRAPH_TILE });
      }
    }
    return points;
  }

  visible(left: number, top: number, right: number, bottom: number) {
    // At overview zoom, iterating occupied cells avoids traversing millions of empty grid cells.
    if ((right - left) * (bottom - top) > this.nodes.length * GRAPH_GAP ** 2 * 4) {
      return this.nodes.filter((node) => node.px >= left && node.px <= right && node.py >= top && node.py <= bottom);
    }
    const result: PlacedNode[] = [];
    for (let x = Math.floor(left / GRAPH_GAP); x <= Math.floor(right / GRAPH_GAP); x++) {
      for (let y = Math.floor(top / GRAPH_GAP); y <= Math.floor(bottom / GRAPH_GAP); y++) {
        for (const node of this.cells.get(cellKey(x, y)) || []) {
          if (node.px >= left && node.px <= right && node.py >= top && node.py <= bottom) { result.push(node); }
        }
      }
    }
    return result;
  }

  hit(point: GraphPoint, zoom: number): PlacedNode | null {
    const radius = 16 / zoom;
    let best: PlacedNode | null = null, distance = radius ** 2;
    for (const node of this.visible(point.px - radius, point.py - radius, point.px + radius, point.py + radius)) {
      const next = (point.px - node.px) ** 2 + (point.py - node.py) ** 2;
      if (next < distance || (next === distance && (!best || node.address < best.address))) { best = node; distance = next; }
    }
    return best;
  }

  visibleEdges(left: number, top: number, right: number, bottom: number): NetEdge[] {
    return this.edgeIndex.visible(left, top, right, bottom);
  }
}
