import { layoutLabels } from './graphLabels';
import { GRAPH_GLYPH_RADIUS } from './graphLayout';
import { GraphScene, PlacedNode } from './graphScene';
import { clamp, GraphViewport } from './graphViewport';
import { GraphPoint } from './mapLayout';
import { ACCESS_COLORS, Gateway, NetEdge, NetEvent } from './types';

export type GraphOverlay = {
  selected: string | null; jacked: string | null; entityHost: string | null;
  gateways: Map<string, Gateway>; selectedRoute: string[]; waypointRoute: string[]; pingRoute: string[];
  events: NetEvent[];
};

const markerColor = (node: PlacedNode) => !node.online ? '#85434a' : ACCESS_COLORS[node.access] || '#678698';
type EdgeGeometry = { from: GraphPoint; to: GraphPoint; signature: string };
type EdgeTransition = EdgeGeometry & { started: number; removed: boolean };

/** Canvas drawing owns transient presentation only; topology and camera remain independent. */
export class GraphRenderer {
  private eventEpoch = 0;
  private events: NetEvent[] = [];
  private changed = new Map<string, number>();
  private points = new Map<string, string>();
  private edges = new Map<string, EdgeGeometry>();
  private edgeTransitions = new Map<string, EdgeTransition>();
  private initialized = false;

  private drawEdges(ctx: CanvasRenderingContext2D, scene: GraphScene, overlay: GraphOverlay, view: GraphViewport,
    width: number, height: number, segment: (a: GraphPoint, b: GraphPoint) => void) {
    const groups = new Map<string, { edges: NetEdge[]; selected: boolean; kind: string; online: boolean }>();
    for (const edge of scene.edges) {
      const selected = view.zoom >= .6 && (edge.from === overlay.selected || edge.to === overlay.selected);
      const key = `${edge.kind}:${edge.online !== false}:${selected}`;
      const group = groups.get(key) || { edges: [], selected, kind: edge.kind, online: edge.online !== false };
      group.edges.push(edge); groups.set(key, group);
    }
    const left = -view.x / view.zoom, top = -view.y / view.zoom;
    const right = (width - view.x) / view.zoom, bottom = (height - view.y) / view.zoom;
    // One stroke per style prevents shared fanout trunks from accumulating opacity thousands of times.
    for (const group of groups.values()) {
      ctx.beginPath();
      for (const edge of group.edges) {
        const a = scene.byAddress.get(edge.from), b = scene.byAddress.get(edge.to);
        if (!a || !b || Math.max(a.px, b.px) < left || Math.min(a.px, b.px) > right || Math.max(a.py, b.py) < top || Math.min(a.py, b.py) > bottom) { continue; }
        segment(a, b);
      }
      ctx.strokeStyle = !group.online ? '#24333e' : group.selected ? '#83b9cc' : group.kind === 'relay' ? '#329a91' : group.kind === 'apc' ? '#345c70' : '#213f51';
      ctx.globalAlpha = view.zoom < .3 && group.kind === 'endpoint' ? .32 : 1;
      ctx.lineWidth = group.selected ? 2 : group.kind === 'endpoint' ? 1 : 1.5;
      ctx.setLineDash(group.online ? [] : [4, 5]); ctx.stroke();
    }
    ctx.globalAlpha = 1; ctx.setLineDash([]);
  }

  private drawEdgeTransitions(ctx: CanvasRenderingContext2D, segment: (a: GraphPoint, b: GraphPoint) => void, now: number) {
    let animating = false;
    for (const [id, transition] of this.edgeTransitions) {
      const progress = (now - transition.started) / 450;
      if (progress >= 1) { this.edgeTransitions.delete(id); continue; }
      animating = true;
      ctx.beginPath(); segment(transition.from, transition.to);
      ctx.globalAlpha = 1 - progress;
      ctx.strokeStyle = transition.removed ? '#ef7982' : '#7ff1cb'; ctx.lineWidth = 2.5;
      ctx.setLineDash(transition.removed ? [5, 4] : []); ctx.stroke();
    }
    ctx.globalAlpha = 1; ctx.setLineDash([]);
    return animating;
  }

  update(scene: GraphScene, events: NetEvent[], now: number) {
    if (events !== this.events) { this.events = events; this.eventEpoch = now; }
    const next = new Map<string, string>();
    for (const node of scene.nodes) {
      const point = `${node.px},${node.py}`;
      if (this.points.size && this.points.get(node.address) !== point) { this.changed.set(node.address, now); }
      next.set(node.address, point);
    }
    this.points = next;
    for (const address of this.changed.keys()) { if (!next.has(address)) { this.changed.delete(address); } }
    const nextEdges = new Map<string, EdgeGeometry>();
    for (const edge of scene.edges) {
      const from = scene.byAddress.get(edge.from), to = scene.byAddress.get(edge.to);
      if (!from || !to) { continue; }
      const geometry = { from: { px: from.px, py: from.py }, to: { px: to.px, py: to.py },
        signature: `${edge.from}:${edge.to}:${edge.kind}:${edge.online}:${from.px},${from.py}:${to.px},${to.py}` };
      nextEdges.set(edge.id, geometry);
      if (this.initialized && this.edges.get(edge.id)?.signature !== geometry.signature) {
        this.edgeTransitions.set(edge.id, { ...geometry, started: now, removed: false });
      }
    }
    for (const [id, geometry] of this.edges) {
      if (!nextEdges.has(id)) { this.edgeTransitions.set(id, { ...geometry, started: now, removed: true }); }
    }
    this.edges = nextEdges;
    this.initialized = true;
  }

  paint(ctx: CanvasRenderingContext2D, scene: GraphScene, view: GraphViewport, overlay: GraphOverlay,
    width: number, height: number, ratio: number, now: number): boolean {
    const { x, y, zoom } = view;
    let animating = false;
    ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
    ctx.fillStyle = '#07111a'; ctx.fillRect(0, 0, width, height);
    const left = -x / zoom, top = -y / zoom, right = (width - x) / zoom, bottom = (height - y) / zoom;
    ctx.strokeStyle = 'rgba(68,122,143,.10)'; ctx.lineWidth = 1; ctx.beginPath();
    const step = clamp(Math.pow(2, Math.ceil(Math.log2(80 / zoom))) * zoom, 32, 240);
    for (let gx = ((x % step) + step) % step; gx < width; gx += step) { ctx.moveTo(gx, 0); ctx.lineTo(gx, height); }
    for (let gy = ((y % step) + step) % step; gy < height; gy += step) { ctx.moveTo(0, gy); ctx.lineTo(width, gy); }
    ctx.stroke(); ctx.save(); ctx.translate(x, y); ctx.scale(zoom, zoom);
    const selectedNeighbors = scene.adjacency.get(overlay.selected);
    const segment = (a: GraphPoint, b: GraphPoint) => {
      const middle = (a.px + b.px) / 2;
      ctx.moveTo(a.px, a.py); ctx.lineTo(middle, a.py); ctx.lineTo(middle, b.py); ctx.lineTo(b.px, b.py);
    };
    this.drawEdges(ctx, scene, overlay, view, width, height, segment);
    const route = (addresses: string[], color: string, dash: number[]) => {
      ctx.beginPath(); ctx.strokeStyle = color; ctx.lineWidth = 3; ctx.setLineDash(dash);
      for (let i = 1; i < addresses.length; i++) {
        const a = scene.byAddress.get(addresses[i - 1]), b = scene.byAddress.get(addresses[i]);
        if (a && b && scene.adjacency.get(a.address)?.has(b.address)) { segment(a, b); }
      }
      ctx.stroke(); ctx.setLineDash([]);
    };
    route(overlay.selectedRoute, '#41dcb5', []);
    route(overlay.waypointRoute, '#e879b8', [8, 5]);
    route(overlay.pingRoute, '#ffc56b', [4, 5]);
    animating = this.drawEdgeTransitions(ctx, segment, now);
    const visible = scene.visible(left - GRAPH_GLYPH_RADIUS, top - GRAPH_GLYPH_RADIUS, right + GRAPH_GLYPH_RADIUS, bottom + GRAPH_GLYPH_RADIUS);
    for (const node of visible) {
      const selected = node.address === overlay.selected, host = node.address === overlay.entityHost, jacked = node.address === overlay.jacked;
      const important = selected || host || jacked;
      const gateway = overlay.gateways.get(node.network);
      const color = markerColor(node);
      const changed = this.changed.get(node.address), progress = changed === undefined ? 1 : (now - changed) / 350;
      if (progress >= 1) { this.changed.delete(node.address); }
      else { animating = true; }
      // No minimum screen-space size: all geometry always fits inside a 48-world-unit square.
      if (important || node.ice || progress < 1) {
        ctx.beginPath(); ctx.arc(node.px, node.py, 20, 0, Math.PI * 2);
        ctx.fillStyle = host ? '#46283e' : node.ice ? '#47232d' : '#183b46'; ctx.fill();
        ctx.strokeStyle = selected ? '#eafff5' : host ? '#f8a3e6' : node.ice ? '#dd667b' : '#65b4d5';
        ctx.lineWidth = 1.5; ctx.stroke();
      }
      ctx.beginPath();
      if (node.type === 'apc') { ctx.rect(node.px - 11, node.py - 11, 22, 22); }
      else if (['gateway', 'relay', 'server', 'terminal'].includes(node.type)) {
        ctx.moveTo(node.px, node.py - 12); ctx.lineTo(node.px + 12, node.py); ctx.lineTo(node.px, node.py + 12); ctx.lineTo(node.px - 12, node.py); ctx.closePath();
      } else { ctx.arc(node.px, node.py, 8, 0, Math.PI * 2); }
      ctx.fillStyle = color; ctx.fill();
      ctx.lineWidth = selectedNeighbors?.has(node.address) ? 2.5 : 1.5;
      ctx.strokeStyle = important ? '#d9f2f2' : gateway?.color || '#527287'; ctx.stroke();
      if (node.entities) { ctx.fillStyle = '#f19bdc'; ctx.fillRect(node.px + 13, node.py - 17, 5, 5); }
      if (zoom >= .6 && ['apc', 'server', 'terminal', 'camera'].includes(node.type)) {
        ctx.strokeStyle = '#102331'; ctx.lineWidth = 1.5; ctx.beginPath();
        ctx.moveTo(node.px - 4, node.py); ctx.lineTo(node.px + 4, node.py);
        if (node.type === 'apc') { ctx.moveTo(node.px, node.py - 4); ctx.lineTo(node.px, node.py + 4); }
        ctx.stroke();
      }
    }
    for (const event of this.events) {
      const age = event.age + (now - this.eventEpoch) / 1000;
      if (age >= 4) { continue; }
      const point = scene.byAddress.get(event.to) || scene.byAddress.get(event.from);
      if (!point) { continue; }
      animating = true;
      ctx.beginPath(); ctx.arc(point.px, point.py, 21 + Math.sin(age * 5) * 1.5, 0, Math.PI * 2);
      ctx.strokeStyle = event.kind === 'trace' ? `rgba(245,102,112,${(4 - age) / 5})` : `rgba(255,194,107,${(4 - age) / 5})`;
      ctx.lineWidth = 1.5; ctx.stroke();
    }
    ctx.restore(); ctx.font = '11px monospace'; ctx.textAlign = 'left';
    const priority = (node: PlacedNode) => node.address === overlay.selected ? 5 : node.address === overlay.entityHost ? 4 : node.address === overlay.jacked ? 3 : node.ice ? 2 : 0;
    const caption = (node: PlacedNode) => {
      if (!['apc', 'gateway', 'relay'].includes(node.type)) { return node.name; }
      const code = overlay.gateways.get(node.network)?.code;
      const sector = node.sector?.replace('sector:', 'S');
      return [code, sector, node.name].filter(Boolean).join(' · ');
    };
    for (const label of layoutLabels(visible, view, width, height - 26, (text) => ctx.measureText(text).width, priority, caption)) {
      ctx.fillStyle = '#0b1d28'; ctx.fillRect(label.rect.left, label.rect.top, label.rect.right - label.rect.left, 19);
      ctx.fillStyle = priority(label.node) ? '#e0f4ef' : '#99b2c1'; ctx.fillText(label.text, label.rect.left + 4, label.rect.top + 13);
    }
    ctx.fillStyle = '#8faebe'; ctx.fillText(`${scene.nodes.length} узлов · ${Math.round(zoom * 100)}%`, 12, height - 11);
    return animating;
  }
}
