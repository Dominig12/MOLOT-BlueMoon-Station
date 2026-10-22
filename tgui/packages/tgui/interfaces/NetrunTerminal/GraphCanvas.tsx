/* eslint-disable react/no-unused-prop-types -- forwardRef accesses typed props through its retained render callbacks. */
import { forwardRef, memo, useCallback, useEffect, useImperativeHandle, useMemo, useRef, useState } from 'react';

import { ActorLayer } from './ActorLayer';
import { GraphOverlay, GraphRenderer } from './graphRenderer';
import { GraphScene, PlacedNode } from './graphScene';
import { clamp, GraphViewport } from './graphViewport';
import { GraphPoint } from './mapLayout';
import { NetEdge, NODE_NAMES, THEME } from './types';

export type GraphCanvasHandle = { center: (address: string) => void; fit: () => void };
type Props = GraphOverlay & {
  nodes: PlacedNode[]; edges: NetEdge[]; positions: Map<string, GraphPoint>;
  actors?: PlacedNode[]; dynamicEdges?: NetEdge[]; suspended?: boolean;
  focus: string | null; adjacency: Map<string, Set<string>>; onSelect: (address: string) => void;
};
const EMPTY_EDGES: NetEdge[] = [];

/** React owns controls/lifecycle; scene, camera and renderer own their respective state. */
export const GraphCanvas = memo(forwardRef<GraphCanvasHandle, Props>((props, externalRef) => {
  const container = useRef<HTMLDivElement>(null), canvas = useRef<HTMLCanvasElement>(null);
  const [view] = useState(() => new GraphViewport());
  const [renderer] = useState(() => new GraphRenderer());
  const [camera, setCamera] = useState({ x: view.x, y: view.y, zoom: view.zoom, width: 720, height: 480 });
  const latest = useRef(props); latest.current = props;
  const frame = useRef<number | null>(null);
  const down = useRef<{ x: number; y: number; panX: number; panY: number; moved: boolean } | null>(null);
  const [tooltip, setTooltip] = useState<{ address: string; x: number; y: number } | null>(null);
  const base = useMemo(() => {
    const value = new GraphScene(); value.update(props.nodes, props.edges); return value;
  }, [props.nodes, props.edges]);
  const scene = useMemo(() => props.actors ? GraphScene.live(base, props.actors, props.adjacency) : base,
    [base, props.actors, props.adjacency]);
  const retained = useRef(scene); retained.current = scene;
  const scenery = useRef(base); scenery.current = base;
  const size = useCallback(() => ({ width: container.current?.clientWidth || 720, height: container.current?.clientHeight || 480 }), []);
  const syncCamera = useCallback(() => {
    const dimensions = size();
    setCamera((previous) => previous.x === view.x && previous.y === view.y && previous.zoom === view.zoom
      && previous.width === dimensions.width && previous.height === dimensions.height ? previous
      : { x: view.x, y: view.y, zoom: view.zoom, ...dimensions });
  }, [view, size]);
  const paintRef = useRef<() => void>(() => {});
  const queuePaint = useCallback(() => {
    if (latest.current.suspended) { return; }
    if (frame.current !== null) { return; }
    if (typeof window.requestAnimationFrame !== 'function') { paintRef.current(); return; }
    frame.current = window.requestAnimationFrame(() => { frame.current = null; paintRef.current(); });
  }, []);
  paintRef.current = () => {
    if (latest.current.suspended) { return; }
    const surface = canvas.current, holder = container.current;
    const ctx = surface?.getContext('2d', { alpha: false });
    if (!surface || !holder || !ctx) { return; }
    const { width, height } = size();
    const ratio = Math.min(2, window.devicePixelRatio || 1, Math.sqrt(5000000 / (width * height)));
    if (surface.width !== Math.ceil(width * ratio) || surface.height !== Math.ceil(height * ratio)) {
      surface.width = Math.ceil(width * ratio); surface.height = Math.ceil(height * ratio);
    }
    // The canvas itself is the retained bitmap cache. There is no animation render loop.
    renderer.paint(ctx, scenery.current, view, latest.current, width, height, ratio);
  };
  const fit = useCallback(() => {
    const { width, height } = size(); view.fit(retained.current.fitPoints(latest.current.apcZones), width, height); syncCamera(); queuePaint();
  }, [view, queuePaint, size, syncCamera]);
  const center = useCallback((address: string) => {
    const point = retained.current.byAddress.get(address);
    if (!point) { return; }
    const { width, height } = size(); view.center(point, width, height); syncCamera(); queuePaint();
  }, [view, queuePaint, size, syncCamera]);
  useImperativeHandle(externalRef, () => ({ center, fit }), [center, fit]);
  useEffect(() => {
    if (props.suspended) {
      if (frame.current !== null) { window.cancelAnimationFrame(frame.current); frame.current = null; }
      setTooltip(null); return;
    }
    // Activity and movable geometry never invalidate the base or automatically change its camera.
    if (view.fitting && retained.current.nodes.length) { fit(); } else { syncCamera(); queuePaint(); }
  }, [base, props.gateways, props.apcZones, props.suspended, view, fit, syncCamera, queuePaint]);
  useEffect(() => {
    if (tooltip && !scene.byAddress.has(tooltip.address)) { setTooltip(null); }
  }, [scene, tooltip]);
  useEffect(() => {
    const el = container.current;
    if (!el) { return; }
    const resized = () => {
      if (latest.current.suspended) { return; }
      if (view.fitting) { fit(); } else { syncCamera(); queuePaint(); }
    };
    const observer = typeof ResizeObserver === 'undefined' ? null : new ResizeObserver(resized);
    observer?.observe(el); window.addEventListener('resize', resized);
    return () => {
      observer?.disconnect(); window.removeEventListener('resize', resized);
      if (frame.current !== null) { window.cancelAnimationFrame(frame.current); frame.current = null; }
    };
  }, [view, fit, syncCamera, queuePaint]);
  const hit = (clientX: number, clientY: number) => {
    const bounds = container.current?.getBoundingClientRect();
    return bounds ? retained.current.hit(view.unproject(clientX - bounds.left, clientY - bounds.top), view.zoom) : null;
  };
  const tooltipNode = tooltip ? scene.byAddress.get(tooltip.address) : null;
  return (
    <div ref={container} data-net-viewport role="application" aria-label="Карта сети"
      style={{ position: 'relative', flex: '1 1 auto', minHeight: '190px', minWidth: 0, overflow: 'hidden', touchAction: 'none', cursor: 'grab', outline: 'none' }}
      tabIndex={0}
      onPointerDown={(event) => {
        if (event.button !== 0) { return; }
        down.current = { x: event.clientX, y: event.clientY, panX: view.x, panY: view.y, moved: false };
        event.currentTarget.focus(); event.currentTarget.setPointerCapture?.(event.pointerId);
      }}
      onPointerMove={(event) => {
        const press = down.current;
        if (press) {
          const dx = event.clientX - press.x, dy = event.clientY - press.y;
          if (dx * dx + dy * dy > 16) { press.moved = true; }
          if (press.moved) { view.pan(press.panX + dx, press.panY + dy); setTooltip(null); syncCamera(); queuePaint(); }
          return;
        }
        const node = hit(event.clientX, event.clientY), bounds = event.currentTarget.getBoundingClientRect();
        setTooltip(node ? { address: node.address, x: event.clientX - bounds.left, y: event.clientY - bounds.top } : null);
      }}
      onPointerLeave={() => setTooltip(null)}
      onPointerUp={(event) => {
        const press = down.current; down.current = null;
        if (!press || press.moved) { return; }
        const node = hit(event.clientX, event.clientY); if (node) { latest.current.onSelect(node.address); }
      }}
      onPointerCancel={() => { down.current = null; setTooltip(null); }}
      onWheel={(event) => {
        event.preventDefault(); setTooltip(null);
        const bounds = event.currentTarget.getBoundingClientRect(), dimensions = size();
        const fitted = new GraphViewport(); fitted.fit(retained.current.fitPoints(latest.current.apcZones), dimensions.width, dimensions.height);
        view.zoomAt(event.clientX - bounds.left, event.clientY - bounds.top, event.deltaY, fitted.zoom); syncCamera(); queuePaint();
      }}>
      <canvas ref={canvas} data-net-canvas aria-hidden="true" style={{ display: 'block', width: '100%', height: '100%' }} />
      {!props.suspended && <ActorLayer {...props} scene={scene} dynamicEdges={props.dynamicEdges || EMPTY_EDGES} camera={camera} />}
      {tooltip && tooltipNode && <div role="tooltip" style={{ position: 'absolute', zIndex: 5, left: clamp(tooltip.x + 14, 8, Math.max(8, size().width - 206)), top: clamp(tooltip.y + 12, 8, Math.max(8, size().height - 82)), width: '194px', padding: '8px 10px', pointerEvents: 'none', background: '#102531', border: '1px solid #316178', borderRadius: '6px', color: THEME.text, fontSize: '11px', boxShadow: '0 10px 25px rgba(0,0,0,.3)' }}>
        <div style={{ fontWeight: 700, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{tooltipNode.name}</div>
        <div style={{ opacity: .7, fontFamily: 'monospace' }}>{tooltipNode.address}</div>
        <div style={{ color: tooltipNode.online ? '#74d8b4' : '#ec8f91' }}>{NODE_NAMES[tooltipNode.type] || tooltipNode.type} · {tooltipNode.online ? 'В сети' : 'Не отвечает'}</div>
        <div>{tooltipNode.sector || ''}{tooltipNode.ice ? ` · ICE: ${tooltipNode.ice}` : ''}{tooltipNode.entities ? ` · процессы: ${tooltipNode.entities}` : ''}</div>
        <div>X {tooltipNode.x} · Y {tooltipNode.y} · Z {tooltipNode.z ?? '—'}</div>
                                 </div>}
    </div>
  );
}));
