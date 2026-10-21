import { GRAPH_GAP } from './graphLayout';
import { graphAdjacency, GraphPoint } from './mapLayout';
import { NetEdge, NetNode } from './types';

export type PlacedNode = NetNode & GraphPoint;
const cellKey = (x: number, y: number) => `${x},${y}`;

/** Retained render scene with a separate spatial index; it never requests hidden nodes. */
export class GraphScene {
  nodes: PlacedNode[] = [];
  edges: NetEdge[] = [];
  byAddress = new Map<string, PlacedNode>();
  adjacency = new Map<string, Set<string>>();
  private cells = new Map<string, PlacedNode[]>();

  update(nodes: PlacedNode[], edges: NetEdge[]) {
    this.nodes = nodes;
    this.edges = edges;
    this.byAddress = new Map(nodes.map((node) => [node.address, node]));
    this.adjacency = graphAdjacency(nodes, edges);
    this.cells.clear();
    for (const node of nodes) {
      const key = cellKey(Math.floor(node.px / GRAPH_GAP), Math.floor(node.py / GRAPH_GAP));
      const cell = this.cells.get(key) || [];
      cell.push(node); this.cells.set(key, cell);
    }
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
}
