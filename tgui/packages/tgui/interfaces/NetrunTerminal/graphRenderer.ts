import { layoutLabels } from './graphLabels';
import { GRAPH_GLYPH_RADIUS, GRAPH_TILE } from './graphLayout';
import { GraphScene, PlacedNode } from './graphScene';
import { clamp, GraphViewport } from './graphViewport';
import { GraphPoint } from './mapLayout';
import { ACCESS_COLORS, ApcZone, Gateway, NetEdge, NetEvent } from './types';

export type GraphOverlay = {
  selected: string | null; jacked: string | null; entityHost: string | null;
  gateways: Map<string, Gateway>; selectedRoute: string[]; waypointRoute: string[]; pingRoute: string[];
  events: NetEvent[];
  apcZones?: ApcZone[];
};
export type GraphBase = Pick<GraphOverlay, 'gateways' | 'apcZones'>;

export const markerColor = (node: PlacedNode) => !node.online ? '#85434a' : ACCESS_COLORS[node.access] || '#678698';
export const physicalPoint = (node: PlacedNode): GraphPoint => ({ px: node.anchorX ?? node.px, py: node.anchorY ?? node.py });

/** Draws only stationary scenery. Its canvas is retained until scenery or the camera changes. */
export class GraphRenderer {
  private drawShape(ctx: CanvasRenderingContext2D, node: PlacedNode) {
    if (node.type === 'apc') { ctx.rect(node.px - 11, node.py - 11, 22, 22); }
    else if (['gateway', 'relay'].includes(node.type)) {
      for (let corner = 0; corner < 6; corner++) {
        const angle = corner * Math.PI / 3, px = node.px + Math.cos(angle) * 14, py = node.py + Math.sin(angle) * 14;
        if (!corner) { ctx.moveTo(px, py); } else { ctx.lineTo(px, py); }
      }
      ctx.closePath();
    } else if (['server', 'terminal'].includes(node.type)) {
      ctx.moveTo(node.px, node.py - 12); ctx.lineTo(node.px + 12, node.py); ctx.lineTo(node.px, node.py + 12); ctx.lineTo(node.px - 12, node.py); ctx.closePath();
    } else { ctx.arc(node.px, node.py, 8, 0, Math.PI * 2); }
  }

  private drawEdges(ctx: CanvasRenderingContext2D, scene: GraphScene, view: GraphViewport,
    width: number, height: number) {
    const groups = new Map<string, { edges: NetEdge[]; kind: string; online: boolean }>();
    for (const edge of scene.edges) {
      const key = `${edge.kind}:${edge.online !== false}`;
      const group = groups.get(key) || { edges: [], kind: edge.kind, online: edge.online !== false };
      group.edges.push(edge); groups.set(key, group);
    }
    const left = -view.x / view.zoom, top = -view.y / view.zoom;
    const right = (width - view.x) / view.zoom, bottom = (height - view.y) / view.zoom;
    // One stroke per style prevents dense APC spokes from accumulating opacity.
    for (const group of groups.values()) {
      ctx.beginPath();
      for (const edge of group.edges) {
        const a = scene.byAddress.get(edge.from), b = scene.byAddress.get(edge.to);
        if (!a || !b) { continue; }
        const from = physicalPoint(a), to = physicalPoint(b);
        if (Math.max(from.px, to.px) < left || Math.min(from.px, to.px) > right || Math.max(from.py, to.py) < top || Math.min(from.py, to.py) > bottom) { continue; }
        ctx.moveTo(from.px, from.py); ctx.lineTo(to.px, to.py);
      }
      ctx.strokeStyle = !group.online ? '#24333e' : group.kind === 'relay' ? '#3fb8ad' : group.kind === 'apc' ? '#3d6d86' : '#274a5f';
      ctx.globalAlpha = view.zoom < .3 && group.kind === 'endpoint' ? .32 : group.kind === 'endpoint' ? .72 : 1;
      ctx.lineWidth = group.kind === 'endpoint' ? 1 : 1.5;
      ctx.setLineDash(group.online ? [] : [4, 5]); ctx.stroke();
    }
    ctx.globalAlpha = 1; ctx.setLineDash([]);
  }

  private drawGeography(ctx: CanvasRenderingContext2D, scene: GraphScene, zones: ApcZone[]) {
    // Server-owned area runs preserve holes and irregular APC borders.
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

  paint(ctx: CanvasRenderingContext2D, scene: GraphScene, view: GraphViewport, base: GraphBase,
    width: number, height: number, ratio: number): void {
    const { x, y, zoom } = view;
    ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
    ctx.lineJoin = 'round'; ctx.lineCap = 'round';
    const backdrop = ctx.createRadialGradient?.(width / 2, height / 2, 0, width / 2, height / 2, Math.max(width, height) * .75);
    if (backdrop) { backdrop.addColorStop(0, '#0c1f2c'); backdrop.addColorStop(1, '#060d15'); ctx.fillStyle = backdrop; }
    else { ctx.fillStyle = '#081420'; }
    ctx.fillRect(0, 0, width, height);
    const left = -x / zoom, top = -y / zoom, right = (width - x) / zoom, bottom = (height - y) / zoom;
    ctx.strokeStyle = 'rgba(70,130,152,.09)'; ctx.lineWidth = 1; ctx.beginPath();
    const step = clamp(Math.pow(2, Math.ceil(Math.log2(80 / zoom))) * zoom, 32, 240);
    for (let gx = ((x % step) + step) % step; gx < width; gx += step) { ctx.moveTo(gx, 0); ctx.lineTo(gx, height); }
    for (let gy = ((y % step) + step) % step; gy < height; gy += step) { ctx.moveTo(0, gy); ctx.lineTo(width, gy); }
    ctx.stroke(); ctx.save(); ctx.translate(x, y); ctx.scale(zoom, zoom);
    this.drawGeography(ctx, scene, base.apcZones || []);
    this.drawEdges(ctx, scene, view, width, height);
    const visible = scene.visible(left - GRAPH_GLYPH_RADIUS, top - GRAPH_GLYPH_RADIUS, right + GRAPH_GLYPH_RADIUS, bottom + GRAPH_GLYPH_RADIUS);
    for (const node of visible) {
      ctx.beginPath(); this.drawShape(ctx, node);
      ctx.fillStyle = markerColor(node); ctx.fill(); ctx.lineWidth = 1.5;
      ctx.strokeStyle = base.gateways.get(node.network)?.color || '#527287'; ctx.stroke();
      if (zoom >= .6 && ['apc', 'server', 'terminal', 'camera'].includes(node.type)) {
        ctx.strokeStyle = '#102331'; ctx.lineWidth = 1.5; ctx.beginPath();
        ctx.moveTo(node.px - 4, node.py); ctx.lineTo(node.px + 4, node.py);
        if (node.type === 'apc') { ctx.moveTo(node.px, node.py - 4); ctx.lineTo(node.px, node.py + 4); }
        ctx.stroke();
      }
    }
    ctx.restore(); ctx.font = '11px monospace'; ctx.textAlign = 'left';
    const caption = (node: PlacedNode) => {
      if (!['apc', 'gateway', 'relay'].includes(node.type)) { return node.name; }
      return [base.gateways.get(node.network)?.code, node.sector?.replace('sector:', 'S'), node.name].filter(Boolean).join(' · ');
    };
    for (const label of layoutLabels(visible, view, width, height - 26, (text) => ctx.measureText(text).width, () => 0, caption)) {
      ctx.fillStyle = '#0b1d28'; ctx.fillRect(label.rect.left, label.rect.top, label.rect.right - label.rect.left, 19);
      ctx.fillStyle = '#99b2c1'; ctx.fillText(label.text, label.rect.left + 4, label.rect.top + 13);
    }
  }
  /** Paint a large scene on a private canvas across several animation frames. */
  *paintChunks(ctx: CanvasRenderingContext2D, scene: GraphScene, view: GraphViewport, base: GraphBase,
    width: number, height: number, ratio: number, chunk = 192): Generator<void, void, unknown> {
    const { x, y, zoom } = view;
    ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
    ctx.lineJoin = 'round'; ctx.lineCap = 'round';
    const backdrop = ctx.createRadialGradient?.(width / 2, height / 2, 0, width / 2, height / 2, Math.max(width, height) * .75);
    if (backdrop) { backdrop.addColorStop(0, '#0c1f2c'); backdrop.addColorStop(1, '#060d15'); ctx.fillStyle = backdrop; }
    else { ctx.fillStyle = '#081420'; }
    ctx.fillRect(0, 0, width, height);
    const left = -x / zoom, top = -y / zoom, right = (width - x) / zoom, bottom = (height - y) / zoom;
    ctx.strokeStyle = 'rgba(70,130,152,.09)'; ctx.lineWidth = 1; ctx.beginPath();
    const step = clamp(Math.pow(2, Math.ceil(Math.log2(80 / zoom))) * zoom, 32, 240);
    for (let gx = ((x % step) + step) % step; gx < width; gx += step) { ctx.moveTo(gx, 0); ctx.lineTo(gx, height); }
    for (let gy = ((y % step) + step) % step; gy < height; gy += step) { ctx.moveTo(0, gy); ctx.lineTo(width, gy); }
    ctx.stroke(); ctx.save(); ctx.translate(x, y); ctx.scale(zoom, zoom);
    let work = 0;
    ctx.fillStyle = 'rgba(64,149,188,.16)';
    for (const zone of base.apcZones || []) {
      for (const run of zone.runs) {
        ctx.fillRect((run.x - .5) * GRAPH_TILE, -(run.y + .5) * GRAPH_TILE, run.width * GRAPH_TILE, GRAPH_TILE);
        if (++work >= chunk) { work = 0; yield; }
      }
    }
    ctx.strokeStyle = 'rgba(117,163,180,.45)'; ctx.lineWidth = 1; ctx.setLineDash([2, 3]); ctx.beginPath();
    for (const node of scene.nodes) {
      const anchor = physicalPoint(node);
      if (anchor.px !== node.px || anchor.py !== node.py) { ctx.moveTo(anchor.px, anchor.py); ctx.lineTo(node.px, node.py); }
      if (++work >= chunk) { work = 0; yield; }
    }
    ctx.stroke(); ctx.setLineDash([]);
    const groups = new Map<string, { edges: NetEdge[]; kind: string; online: boolean }>();
    for (const edge of scene.edges) {
      const key = edge.kind + ':' + String(edge.online !== false);
      const group = groups.get(key) || { edges: [], kind: edge.kind, online: edge.online !== false };
      group.edges.push(edge); groups.set(key, group);
      if (++work >= chunk) { work = 0; yield; }
    }
    for (const group of groups.values()) {
      ctx.beginPath();
      for (const edge of group.edges) {
        const a = scene.byAddress.get(edge.from), b = scene.byAddress.get(edge.to);
        if (a && b) {
          const from = physicalPoint(a), to = physicalPoint(b);
          if (!(Math.max(from.px, to.px) < left || Math.min(from.px, to.px) > right
            || Math.max(from.py, to.py) < top || Math.min(from.py, to.py) > bottom)) {
            ctx.moveTo(from.px, from.py); ctx.lineTo(to.px, to.py);
          }
        }
        if (++work >= chunk) { work = 0; yield; }
      }
      ctx.strokeStyle = !group.online ? '#24333e'
        : group.kind === 'relay' ? '#3fb8ad' : group.kind === 'apc' ? '#3d6d86' : '#274a5f';
      ctx.globalAlpha = zoom < .3 && group.kind === 'endpoint' ? .32 : group.kind === 'endpoint' ? .72 : 1;
      ctx.lineWidth = group.kind === 'endpoint' ? 1 : 1.5;
      ctx.setLineDash(group.online ? [] : [4, 5]); ctx.stroke();
    }
    ctx.globalAlpha = 1; ctx.setLineDash([]);
    const visible = scene.visible(left - GRAPH_GLYPH_RADIUS, top - GRAPH_GLYPH_RADIUS,
      right + GRAPH_GLYPH_RADIUS, bottom + GRAPH_GLYPH_RADIUS);
    for (const node of visible) {
      ctx.beginPath(); this.drawShape(ctx, node);
      ctx.fillStyle = markerColor(node); ctx.fill(); ctx.lineWidth = 1.5;
      ctx.strokeStyle = base.gateways.get(node.network)?.color || '#527287'; ctx.stroke();
      if (zoom >= .6 && ['apc', 'server', 'terminal', 'camera'].includes(node.type)) {
        ctx.strokeStyle = '#102331'; ctx.lineWidth = 1.5; ctx.beginPath();
        ctx.moveTo(node.px - 4, node.py); ctx.lineTo(node.px + 4, node.py);
        if (node.type === 'apc') { ctx.moveTo(node.px, node.py - 4); ctx.lineTo(node.px, node.py + 4); }
        ctx.stroke();
      }
      if (++work >= chunk) { work = 0; yield; }
    }
    ctx.restore(); ctx.font = '11px monospace'; ctx.textAlign = 'left';
    const caption = (node: PlacedNode) => {
      if (!['apc', 'gateway', 'relay'].includes(node.type)) { return node.name; }
      return [base.gateways.get(node.network)?.code, node.sector?.replace('sector:', 'S'), node.name].filter(Boolean).join(' · ');
    };
    const labels = layoutLabels(visible, view, width, height - 26, (text) => ctx.measureText(text).width, () => 0, caption);
    yield;
    for (const label of labels) {
      ctx.fillStyle = '#0b1d28'; ctx.fillRect(label.rect.left, label.rect.top, label.rect.right - label.rect.left, 19);
      ctx.fillStyle = '#99b2c1'; ctx.fillText(label.text, label.rect.left + 4, label.rect.top + 13);
      if (++work >= chunk) { work = 0; yield; }
    }
  }

}
