/* eslint-disable react/no-unused-prop-types, complexity -- Canvas reads its typed props through a retained ref in render callbacks. */
/**
 * Netrun network renderer.
 * One canvas, one retained viewport and no DOM/SVG element per vertex.
 * Graph geometry is derived exclusively from the nodes/edges received from DM.
 * Draw only on data/viewport changes; there is no perpetual animation loop.
 */
import { forwardRef, memo, useCallback, useEffect, useImperativeHandle, useMemo, useRef, useState } from 'react';

import { graphBounds, GraphPoint } from './mapLayout';
import { ACCESS_COLORS, Gateway, NetEdge, NetEvent, NetNode, NODE_NAMES, THEME } from './types';

type Placed = NetNode & GraphPoint;
export type GraphCanvasHandle = { center: (address: string) => void; fit: () => void };
type Props = {
  nodes: Placed[];
  edges: NetEdge[];
  positions: Map<string, GraphPoint>;
  gateways: Map<string, Gateway>;
  selected: string | null;
  jacked: string | null;
  focus: string | null;
  entityHost: string | null;
  selectedRoute: string[];
  adjacency: Map<string, Set<string>>;
  waypointRoute: string[];
  pingRoute: string[];
  events: NetEvent[];
  onSelect: (address: string) => void;
};

type View = { x: number; y: number; zoom: number; ready: boolean };
const CELL = 180;
const MIN_ZOOM = 0.08;
const MAX_ZOOM = 2.5;
const clamp = (n: number, min: number, max: number) => Math.max(min, Math.min(max, n));
const gridKey = (x: number, y: number) => `${x},${y}`;
const formatNode = (node: Placed) => (NODE_NAMES[node.type] || node.type).slice(0, 2).toUpperCase();

export const GraphCanvas = memo(forwardRef<GraphCanvasHandle, Props>((props, externalRef) => {
  const container = useRef<HTMLDivElement>(null);
  const canvas = useRef<HTMLCanvasElement>(null);
  const view = useRef<View>({ x: 0, y: 0, zoom: 0.85, ready: false });
  const frame = useRef<number | null>(null);
  const down = useRef<{ x: number; y: number; panX: number; panY: number; moved: boolean } | null>(null);
  const latest = useRef(props);
  latest.current = props;
  const hovered = useRef<string | null>(null);
  const [tooltip, setTooltip] = useState<{ node: Placed; x: number; y: number } | null>(null);

  // Unlike a render loop, the index is rebuilt only when the node set or layout changes.
  const index = useMemo(() => {
    const cells = new Map<string, Placed[]>();
    for (const node of props.nodes) {
      const key = gridKey(Math.floor(node.px / CELL), Math.floor(node.py / CELL));
      const cell = cells.get(key);
      if (cell) { cell.push(node); } else { cells.set(key, [node]); }
    }
    return cells;
  }, [props.nodes]);
  const retained = useRef(index);
  retained.current = index;

  const paint = useCallback(() => {
    const surface = canvas.current;
    const holder = container.current;
    const ctx = surface?.getContext('2d', { alpha: false });
    if (!surface || !holder || !ctx) { return; }
    const width = holder.clientWidth || 720;
    const height = holder.clientHeight || 480;
    if (width < 2 || height < 2) { return; }
    // Cap device-pixel-ratio and total surface area on older embedded browsers.
    const ratio = Math.min(2, window.devicePixelRatio || 1, Math.sqrt(5000000 / (width * height)));
    const deviceWidth = Math.ceil(width * ratio);
    const deviceHeight = Math.ceil(height * ratio);
    if (surface.width !== deviceWidth || surface.height !== deviceHeight) {
      surface.width = deviceWidth; surface.height = deviceHeight;
    }
    const current = latest.current;
    const { x, y, zoom } = view.current;
    ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
    ctx.fillStyle = '#07111a';
    ctx.fillRect(0, 0, width, height);
    const left = -x / zoom;
    const top = -y / zoom;
    const right = (width - x) / zoom;
    const bottom = (height - y) / zoom;
    // Screen-space grid remains crisp on any zoom level.
    ctx.strokeStyle = 'rgba(68,122,143,0.10)';
    ctx.lineWidth = 1;
    const step = clamp(Math.pow(2, Math.ceil(Math.log2(80 / zoom))) * zoom, 32, 240);
    ctx.beginPath();
    for (let gx = ((x % step) + step) % step; gx < width; gx += step) { ctx.moveTo(gx, 0); ctx.lineTo(gx, height); }
    for (let gy = ((y % step) + step) % step; gy < height; gy += step) { ctx.moveTo(0, gy); ctx.lineTo(width, gy); }
    ctx.stroke();
    ctx.save();
    ctx.translate(x, y); ctx.scale(zoom, zoom);
    // Frustum culling: a line is discarded if its AABB is fully offscreen.
    const margin = 28 / zoom;
    for (const edge of current.edges) {
      const a = current.positions.get(edge.from);
      const b = current.positions.get(edge.to);
      if (!a || !b ||
        Math.max(a.px, b.px) < left - margin || Math.min(a.px, b.px) > right + margin ||
        Math.max(a.py, b.py) < top - margin || Math.min(a.py, b.py) > bottom + margin) { continue; }
      ctx.beginPath(); ctx.moveTo(a.px, a.py); ctx.lineTo(b.px, b.py);
      ctx.strokeStyle = edge.online === false ? 'rgba(88,108,121,.17)' :
        edge.kind === 'relay' ? 'rgba(78,214,194,.65)' :
          edge.kind === 'apc' ? 'rgba(94,150,175,.60)' : 'rgba(76,115,141,.40)';
      ctx.lineWidth = (edge.kind === 'endpoint' ? 1.15 : 1.9) / zoom ** 0.32;
      ctx.stroke();
    }
    const drawRoute = (addresses: string[], color: string, width: number, dash: number[] = []) => {
      let previous: GraphPoint | undefined;
      let previousAddress: string | null = null;
      ctx.beginPath();
      ctx.setLineDash(dash);
      ctx.lineWidth = width / zoom ** 0.25;
      ctx.strokeStyle = color;
      for (const address of addresses) {
        const point = current.positions.get(address);
        if (!point) { previous = undefined; previousAddress = null; continue; }
        // Segment validity is checked against supplied edges, not inferred from distance.
        if (previous && previousAddress && current.adjacency.get(previousAddress)?.has(address)) { ctx.lineTo(point.px, point.py); }
        else { ctx.moveTo(point.px, point.py); }
        previous = point; previousAddress = address;
      }
      ctx.stroke(); ctx.setLineDash([]);
    };
    drawRoute(current.selectedRoute, '#41dcb5', 3.3);
    drawRoute(current.waypointRoute, '#e879b8', 3, [8, 5]);
    drawRoute(current.pingRoute, '#ffc56b', 2.6, [4, 5]);
    // Spatial index: visit visible cells instead of all vertices.
    let count = 0;
    const occupiedLabels = new Set<string>();
    for (let gx = Math.floor((left - margin) / CELL); gx <= Math.floor((right + margin) / CELL); gx++) {
      for (let gy = Math.floor((top - margin) / CELL); gy <= Math.floor((bottom + margin) / CELL); gy++) {
        const group = retained.current.get(gridKey(gx, gy));
        if (!group) { continue; }
        for (const node of group) {
          if (node.px < left - margin || node.px > right + margin || node.py < top - margin || node.py > bottom + margin) { continue; }
          count++;
          const selected = node.address === current.selected;
          const host = node.address === current.entityHost;
          const jacked = node.address === current.jacked;
          const highlighted = selected || host || jacked;
          const size = node.type === 'apc' ? 11 : 7.5;
          const fill = !node.online ? '#85434a' : (ACCESS_COLORS[node.access] || '#678698');
          const groupColor = node.network && current.gateways.get(node.network)?.color;
          if (highlighted || node.ice || node.entities) {
            ctx.beginPath(); ctx.arc(node.px, node.py, size + (highlighted ? 7 : 4), 0, Math.PI * 2);
            ctx.fillStyle = host ? 'rgba(222,111,203,.22)' : selected ? 'rgba(76,231,186,.23)' : node.ice ? 'rgba(234,92,104,.18)' : 'rgba(88,194,238,.16)';
            ctx.fill();
          }
          ctx.beginPath();
          if (node.type === 'apc') { ctx.rect(node.px - size, node.py - size, 2 * size, 2 * size); }
          else { ctx.arc(node.px, node.py, size, 0, 2 * Math.PI); }
          ctx.fillStyle = fill; ctx.fill();
          ctx.lineWidth = highlighted ? 3 : 1.3;
          ctx.strokeStyle = selected ? '#f3fff8' : host ? '#f8a3e6' : jacked ? '#68f5bc' : groupColor || '#152c38';
          ctx.stroke();
          if (zoom > 0.64 && (count < 175 || highlighted)) {
            const label = node.name.length > 22 ? `${node.name.slice(0, 21)}…` : node.name;
            ctx.font = `${Math.round(10 / zoom ** .22)}px monospace`;
            const sx = node.px * zoom + x;
            const sy = (node.py + 24) * zoom + y;
            const column = Math.floor(sx / 98), row = Math.floor(sy / 22);
            const slot = `${column},${row}`;
            const neighborsOccupied = [-1, 0, 1].some((d) => occupiedLabels.has(`${column + d},${row}`));
            if (!neighborsOccupied || highlighted) {
              occupiedLabels.add(slot);
              ctx.textAlign = 'center';
              ctx.fillStyle = highlighted ? '#f4fff9' : '#9cb5c1';
              ctx.fillText(label, node.px, node.py + 24, 180);
            }
          }
        }
      }
    }
    for (const event of current.events) {
      const point = current.positions.get(event.to || '') || current.positions.get(event.from || '');
      if (!point || event.age >= 4) { continue; }
      ctx.beginPath(); ctx.arc(point.px, point.py, 12 + event.age * 8, 0, Math.PI * 2);
      ctx.strokeStyle = event.kind === 'trace' ? `rgba(245,102,112,${(4-event.age)/5})` : `rgba(255,194,107,${(4-event.age)/5})`;
      ctx.lineWidth = 2; ctx.stroke();
    }
    ctx.restore();
    ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
    ctx.font = '11px monospace'; ctx.textAlign = 'left';
    ctx.fillStyle = '#8faebe';
    ctx.fillText(`${current.nodes.length} узлов · ${Math.round(zoom * 100)}% · Canvas`, 12, height - 13);
  }, []);
  const queuePaint = useCallback(() => {
    if (frame.current !== null) { return; }
    if (typeof window.requestAnimationFrame !== 'function') { paint(); return; }
    frame.current = window.requestAnimationFrame(() => { frame.current = null; paint(); });
  }, [paint]);
  const center = useCallback((address: string) => {
    const point = latest.current.positions.get(address);
    const holder = container.current;
    if (!holder || !point) { return; }
    view.current.x = holder.clientWidth / 2 - point.px * view.current.zoom;
    view.current.y = holder.clientHeight / 2 - point.py * view.current.zoom;
    view.current.ready = true;
    queuePaint();
  }, [queuePaint]);
  const fit = useCallback(() => {
    const holder = container.current;
    if (!holder || latest.current.nodes.length === 0) { return; }
    const bounds = graphBounds(latest.current.nodes, 80);
    const width = holder.clientWidth || 720; const height = holder.clientHeight || 480;
    const zoom = clamp(Math.min(width / bounds.width, height / bounds.height), MIN_ZOOM, MAX_ZOOM);
    view.current = {
      x: (width - (bounds.minX * 2 + bounds.width) * zoom) / 2,
      y: (height - (bounds.minY * 2 + bounds.height) * zoom) / 2,
      zoom, ready: true,
    };
    queuePaint();
  }, [queuePaint]);
  useImperativeHandle(externalRef, () => ({ center, fit }), [center, fit]);
  useEffect(() => {
    if (!view.current.ready && props.nodes.length) { center(props.focus || props.selected || props.nodes[0].address); }
    queuePaint();
  }, [props, center, queuePaint]);
  useEffect(() => {
    const el = container.current;
    if (!el) { return; }
    const resized = () => queuePaint();
    const observer = typeof ResizeObserver === 'undefined' ? null : new ResizeObserver(resized);
    if (observer) { observer.observe(el); }
    window.addEventListener('resize', resized);
    return () => {
      observer?.disconnect(); window.removeEventListener('resize', resized);
      if (frame.current !== null) { window.cancelAnimationFrame(frame.current); frame.current = null; }
    };
  }, [queuePaint]);

  const hit = (clientX: number, clientY: number): Placed | null => {
    const el = container.current;
    if (!el) { return null; }
    const rect = el.getBoundingClientRect();
    const { x, y, zoom } = view.current;
    const px = (clientX - rect.left - x) / zoom;
    const py = (clientY - rect.top - y) / zoom;
    const gridX = Math.floor(px / CELL); const gridY = Math.floor(py / CELL);
    const radius = 16 / zoom;
    const reach = Math.max(1, Math.ceil(radius / CELL));
    let best: Placed | null = null; let nearest = radius * radius;
    for (let dx = -reach; dx <= reach; dx++) {
      for (let dy = -reach; dy <= reach; dy++) {
        for (const node of retained.current.get(gridKey(gridX + dx, gridY + dy)) || []) {
          const distance = (px - node.px) ** 2 + (py - node.py) ** 2;
          if (distance < nearest) { best = node; nearest = distance; }
        }
      }
    }
    return best;
  };
  return (
    <div ref={container} data-net-viewport role="application" aria-label="Карта сети"
      style={{ position: 'relative', flex: '1 1 auto', minHeight: '140px', minWidth: 0, overflow: 'hidden', touchAction: 'none', cursor: down.current ? 'grabbing' : 'grab', outline: 'none' }}
      tabIndex={0}
      onPointerDown={(event) => {
        if (event.button !== 0) { return; }
        const v = view.current;
        down.current = { x: event.clientX, y: event.clientY, panX: v.x, panY: v.y, moved: false };
        event.currentTarget.focus();
        event.currentTarget.setPointerCapture?.(event.pointerId);
      }}
      onPointerMove={(event) => {
        const press = down.current;
        if (press) {
          const dx = event.clientX - press.x, dy = event.clientY - press.y;
          if (dx * dx + dy * dy > 16) { press.moved = true; }
          if (press.moved) {
            view.current.x = press.panX + dx; view.current.y = press.panY + dy;
            if (hovered.current) { hovered.current = null; setTooltip(null); }
            queuePaint();
          }
          return;
        }
        const node = hit(event.clientX, event.clientY);
        if ((node?.address || null) !== hovered.current) {
          hovered.current = node?.address || null;
          const bounds = event.currentTarget.getBoundingClientRect();
          setTooltip(node ? { node, x: event.clientX - bounds.left, y: event.clientY - bounds.top } : null);
        }
      }}
      onPointerUp={(event) => {
        const press = down.current;
        down.current = null;
        if (press && !press.moved) {
          const node = hit(event.clientX, event.clientY);
          if (node) { latest.current.onSelect(node.address); }
        }
      }}
      onPointerCancel={() => { down.current = null; }}
      onWheel={(event) => {
        event.preventDefault();
        const bounds = event.currentTarget.getBoundingClientRect();
        const sx = event.clientX - bounds.left, sy = event.clientY - bounds.top;
        const v = view.current;
        const next = clamp(v.zoom * Math.exp(-event.deltaY * .0013), MIN_ZOOM, MAX_ZOOM);
        v.x = sx - (sx - v.x) * (next / v.zoom);
        v.y = sy - (sy - v.y) * (next / v.zoom);
        v.zoom = next;
        queuePaint();
      }}>
      <canvas ref={canvas} data-net-canvas aria-hidden="true" style={{ display: 'block', width: '100%', height: '100%' }} />
      {tooltip && <div style={{ position: 'absolute', zIndex: 5, left: clamp(tooltip.x + 14, 8, Math.max(8, (container.current?.clientWidth || 600) - 206)), top: clamp(tooltip.y + 12, 8, Math.max(8, (container.current?.clientHeight || 400) - 62)), width: '194px', padding: '8px 10px', pointerEvents: 'none', background: '#102531', border: '1px solid #316178', borderRadius: '6px', color: THEME.text, fontSize: '11px', boxShadow: '0 10px 25px rgba(0,0,0,.3)' }}>
        <div style={{ fontWeight: 700, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{tooltip.node.name}</div>
        <div style={{ opacity: .7, fontFamily: 'monospace' }}>{tooltip.node.address}</div>
        <div style={{ color: tooltip.node.online ? '#74d8b4' : '#ec8f91' }}>{formatNode(tooltip.node)} · {tooltip.node.online ? 'В сети' : 'Не отвечает'}</div>
                  </div>}
    </div>
  );
}));
