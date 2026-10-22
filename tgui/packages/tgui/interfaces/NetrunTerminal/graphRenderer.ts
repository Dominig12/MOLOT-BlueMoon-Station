import { layoutLabels } from './graphLabels';
import { GRAPH_GLYPH_RADIUS, GRAPH_TILE } from './graphLayout';
import { GraphScene, PlacedNode } from './graphScene';
import { clamp, GraphViewport } from './graphViewport';
import { GraphPoint } from './mapLayout';
import { ACCESS_COLORS, ApcZone, Gateway, NetEdge } from './types';

export type GraphOverlay = {
  selected: string | null; jacked: string | null; entityHost: string | null;
  gateways: Map<string, Gateway>; selectedRoute: string[]; waypointRoute: string[]; pingRoute: string[];
  apcZones?: ApcZone[];
};

const markerColor = (node: PlacedNode) => !node.online ? '#85434a' : ACCESS_COLORS[node.access] || '#678698';
const physicalPoint = (node: PlacedNode): GraphPoint => ({ px: node.anchorX ?? node.px, py: node.anchorY ?? node.py });
type EdgeGeometry = { from: GraphPoint; to: GraphPoint; signature: string };
type EdgeTransition = EdgeGeometry & { started: number; removed: boolean };

/** Canvas draws only the static graph (structure, status, labels); moving actors and event
 * pulses live in the reactive DOM layer above, so a status tick never repaints the canvas. */
export class GraphRenderer {
  private changed = new Map<string, number>();
  private points = new Map<string, string>();
  private edges = new Map<string, EdgeGeometry>();
  private edgeTransitions = new Map<string, EdgeTransition>();
  private initialized = false;

  private drawShape(ctx: CanvasRenderingContext2D, node: PlacedNode) {
      if (node.type === 'apc') { ctx.rect(node.px - 11, node.py - 11, 22, 22); }
      else if (['gateway', 'relay'].includes(node.type)) {
        for (let corner = 0; corner < 6; corner++) {
          const angle = corner * Math.PI / 3, px = node.px + Math.cos(angle) * 14, py = node.py + Math.sin(angle) * 14;
          if (!corner) { ctx.moveTo(px, py); } else { ctx.lineTo(px, py); }
        }
        ctx.closePath();
      }
      else if (['server', 'terminal'].includes(node.type)) {
        ctx.moveTo(node.px, node.py - 12); ctx.lineTo(node.px + 12, node.py); ctx.lineTo(node.px, node.py + 12); ctx.lineTo(node.px - 12, node.py); ctx.closePath();
      } else { ctx.arc(node.px, node.py, 8, 0, Math.PI * 2); }
  }

  private drawEdges(ctx: CanvasRenderingContext2D, scene: GraphScene, overlay: GraphOverlay, view: GraphViewport,
    width: number, height: number, straight: (a: GraphPoint, b: GraphPoint) => void) {
    const groups = new Map<string, { edges: NetEdge[]; selected: boolean; kind: string; online: boolean }>();
    for (const edge of scene.edges) {
      const selected = view.zoom >= .6 && (edge.from === overlay.selected || edge.to === overlay.selected);
      const key = `${edge.kind}:${edge.online !== false}:${selected}`;
      const group = groups.get(key) || { edges: [], selected, kind: edge.kind, online: edge.online !== false };
      group.edges.push(edge); groups.set(key, group);
    }
    const left = -view.x / view.zoom, top = -view.y / view.zoom;
    const right = (width - view.x) / view.zoom, bottom = (height - view.y) / view.zoom;
    const denseSelection = (scene.adjacency.get(overlay.selected)?.size || 0) > 24;
    // One stroke per style prevents shared fanout trunks from accumulating opacity thousands of times.
    for (const group of groups.values()) {
      // Every tree link — including a selected node's — is a straight spoke to its parent,
      // so highlighting a path looks exactly like the edges it runs along.
      ctx.beginPath();
      for (const edge of group.edges) {
        const a = scene.byAddress.get(edge.from), b = scene.byAddress.get(edge.to);
        if (!a || !b || Math.max(a.px, b.px) < left || Math.min(a.px, b.px) > right || Math.max(a.py, b.py) < top || Math.min(a.py, b.py) > bottom) { continue; }
        straight(physicalPoint(a), physicalPoint(b));
      }
      ctx.strokeStyle = !group.online ? '#24333e' : group.selected ? '#9ad0e0' : group.kind === 'relay' ? '#3fb8ad' : group.kind === 'apc' ? '#3d6d86' : '#274a5f';
      ctx.globalAlpha = group.selected && denseSelection ? .22 : view.zoom < .3 && group.kind === 'endpoint' ? .32 : group.kind === 'endpoint' ? .72 : 1;
      ctx.lineWidth = group.selected && !denseSelection ? 2.5 : group.kind === 'endpoint' ? 1 : 1.5;
      ctx.setLineDash(group.online ? [] : [4, 5]); ctx.stroke();
    }
    ctx.globalAlpha = 1; ctx.setLineDash([]);
  }

  private drawGeography(ctx: CanvasRenderingContext2D, scene: GraphScene, zones: ApcZone[]) {
    // These runs are the actual server-owned APC area tiles, including holes and irregular borders.
    ctx.fillStyle = 'rgba(64,149,188,.16)';
    for (const zone of zones) {
      for (const run of zone.runs) {
        ctx.fillRect((run.x - .5) * GRAPH_TILE, -(run.y + .5) * GRAPH_TILE, run.width * GRAPH_TILE, GRAPH_TILE);
      }
    }
    ctx.strokeStyle = 'rgba(117,163,180,.45)'; ctx.lineWidth = 1; ctx.setLineDash([2, 3]); ctx.beginPath();
    for (const node of scene.nodes) {
      const anchor = physicalPoint(node);
      if (anchor.px !== node.px || anchor.py !== node.py) { ctx.moveTo(anchor.px, anchor.py); ctx.lineTo(node.px, node.py); }
    }
    ctx.stroke(); ctx.setLineDash([]);
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

  update(scene: GraphScene, now: number) {
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
      const geometry = { from: physicalPoint(from), to: physicalPoint(to),
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
    ctx.lineJoin = 'round'; ctx.lineCap = 'round';
    // Soft radial depth instead of a flat fill reads as a lit console surface.
    const backdrop = ctx.createRadialGradient?.(width / 2, height / 2, 0, width / 2, height / 2, Math.max(width, height) * 0.75);
    if (backdrop) { backdrop.addColorStop(0, '#0c1f2c'); backdrop.addColorStop(1, '#060d15'); ctx.fillStyle = backdrop; }
    else { ctx.fillStyle = '#081420'; }
    ctx.fillRect(0, 0, width, height);
    const left = -x / zoom, top = -y / zoom, right = (width - x) / zoom, bottom = (height - y) / zoom;
    ctx.strokeStyle = 'rgba(70,130,152,.09)'; ctx.lineWidth = 1; ctx.beginPath();
    const step = clamp(Math.pow(2, Math.ceil(Math.log2(80 / zoom))) * zoom, 32, 240);
    for (let gx = ((x % step) + step) % step; gx < width; gx += step) { ctx.moveTo(gx, 0); ctx.lineTo(gx, height); }
    for (let gy = ((y % step) + step) % step; gy < height; gy += step) { ctx.moveTo(0, gy); ctx.lineTo(width, gy); }
    ctx.stroke(); ctx.save(); ctx.translate(x, y); ctx.scale(zoom, zoom);
    this.drawGeography(ctx, scene, overlay.apcZones || []);
    const selectedNeighbors = scene.adjacency.get(overlay.selected);
    const straight = (a: GraphPoint, b: GraphPoint) => { ctx.moveTo(a.px, a.py); ctx.lineTo(b.px, b.py); };
    this.drawEdges(ctx, scene, overlay, view, width, height, straight);
    // A static highlight (the animated "marching ants" flow moved to the DOM layer so the
    // canvas is not forced to repaint while a route is shown).
    const route = (addresses: string[], color: string, dash: number[]) => {
      ctx.beginPath(); ctx.strokeStyle = color; ctx.lineWidth = 3.5;
      ctx.setLineDash(dash);
      ctx.shadowBlur = 8; ctx.shadowColor = color;
      for (let i = 1; i < addresses.length; i++) {
        const a = scene.byAddress.get(addresses[i - 1]), b = scene.byAddress.get(addresses[i]);
        if (a && b && scene.adjacency.get(a.address)?.has(b.address)) { straight(physicalPoint(a), physicalPoint(b)); }
      }
      ctx.stroke(); ctx.setLineDash([]); ctx.shadowBlur = 0;
    };
    route(overlay.selectedRoute, '#50e8c0', [11, 7]);
    route(overlay.waypointRoute, '#e879b8', [8, 5]);
    route(overlay.pingRoute, '#ffc56b', [4, 5]);
    animating = this.drawEdgeTransitions(ctx, straight, now) || animating;
    const visible = scene.visible(left - GRAPH_GLYPH_RADIUS, top - GRAPH_GLYPH_RADIUS, right + GRAPH_GLYPH_RADIUS, bottom + GRAPH_GLYPH_RADIUS);
    for (const node of visible) {
      const selected = node.address === overlay.selected, host = node.address === overlay.entityHost, jacked = node.address === overlay.jacked;
      const important = selected || host || jacked;
      const gateway = overlay.gateways.get(node.network);
      const color = markerColor(node);
      const changed = this.changed.get(node.address), progress = changed === undefined ? 1 : (now - changed) / 350;
      if (progress >= 1) { this.changed.delete(node.address); }
      else { animating = true; }
      // Moving actors (entities/ICE), their pulses and event ripples are drawn by the DOM layer.
      // No minimum screen-space size: all geometry always fits inside a 48-world-unit square.
      if (important || progress < 1) {
        ctx.beginPath(); ctx.arc(node.px, node.py, 20, 0, Math.PI * 2);
        ctx.fillStyle = host ? '#46283e' : '#183b46'; ctx.fill();
        ctx.strokeStyle = selected ? '#eafff5' : host ? '#f8a3e6' : '#65b4d5';
        ctx.lineWidth = 1.5; ctx.stroke();
      }
      // Glow lifts key nodes off the board without enlarging their footprint.
      if (important && zoom >= .45) { ctx.shadowBlur = 16; ctx.shadowColor = selected ? '#9dffe4' : host ? '#f8a3e6' : '#9ad0e0'; }
      ctx.beginPath();
      this.drawShape(ctx, node);
      ctx.fillStyle = color; ctx.fill();
      ctx.lineWidth = selectedNeighbors?.has(node.address) ? 2.5 : 1.5;
      ctx.strokeStyle = important ? '#d9f2f2' : gateway?.color || '#527287'; ctx.stroke();
      ctx.shadowBlur = 0;
      if (zoom >= .6 && ['apc', 'server', 'terminal', 'camera'].includes(node.type)) {
        ctx.strokeStyle = '#102331'; ctx.lineWidth = 1.5; ctx.beginPath();
        ctx.moveTo(node.px - 4, node.py); ctx.lineTo(node.px + 4, node.py);
        if (node.type === 'apc') { ctx.moveTo(node.px, node.py - 4); ctx.lineTo(node.px, node.py + 4); }
        ctx.stroke();
      }
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
    ctx.fillStyle = '#8faebe'; ctx.fillText(`Север ↑ · ${scene.nodes.length} узлов · ${Math.round(zoom * 100)}%`, 12, height - 11);
    return animating;
  }
}
