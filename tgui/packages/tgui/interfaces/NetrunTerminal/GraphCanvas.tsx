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
  const paintVersion = useRef(0);
  const paintJob = useRef<{ version: number; iterator: Generator<void, void, unknown>; surface: HTMLCanvasElement; viewport: GraphViewport } | null>(null);
  const paintedView = useRef<{ x: number; y: number; zoom: number } | null>(null);
  // Wheel events frequently arrive several times per frame. A fitted view only
  // changes when scene geometry, powered-area runs or viewport dimensions change.
  const fittedView = useRef<{ scene: GraphScene; zones: Props['apcZones'];
    width: number; height: number; x: number; y: number; zoom: number } | null>(null);
  const wheelActive = useRef(false);
  const wheelFinish = useRef<number | null>(null);
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
  const fitting = useCallback((width: number, height: number) => {
    const scene = retained.current;
    const zones = latest.current.apcZones;
    const previous = fittedView.current;
    if (previous?.scene === scene && previous.zones === zones
      && previous.width === width && previous.height === height) { return previous; }
    const candidate = new GraphViewport();
    candidate.fit(scene.fitPoints(zones), width, height);
    const result = { scene, zones, width, height, x: candidate.x, y: candidate.y, zoom: candidate.zoom };
    fittedView.current = result;
    return result;
  }, []);
  const syncCamera = useCallback(() => {
    const dimensions = size();
    setCamera((previous) => previous.x === view.x && previous.y === view.y && previous.zoom === view.zoom
      && previous.width === dimensions.width && previous.height === dimensions.height ? previous
      : { x: view.x, y: view.y, zoom: view.zoom, ...dimensions });
  }, [view, size]);
  // Keep the last bitmap in camera coordinates while SVG moves with current camera.
  const syncBitmapCamera = useCallback(() => {
    const surface = canvas.current, previous = paintedView.current;
    if (!surface || !previous) { return; }
    const scale = view.zoom / previous.zoom;
    const dx = view.x - previous.x * scale, dy = view.y - previous.y * scale;
    surface.style.transformOrigin = '0 0';
    surface.style.transform = 'translate(' + dx + 'px, ' + dy + 'px) scale(' + scale + ')';
  }, [view]);
  const paintRef = useRef<() => void>(() => {});
  const schedulePaint = useCallback(() => {
    if (latest.current.suspended || frame.current !== null) { return; }
    if (typeof window.requestAnimationFrame !== 'function') { paintRef.current(); return; }
    frame.current = window.requestAnimationFrame(() => { frame.current = null; paintRef.current(); });
  }, []);
  const queuePaint = useCallback(() => {
    paintVersion.current++;
    paintJob.current = null;
    schedulePaint();
  }, [schedulePaint]);
  paintRef.current = () => {
    if (latest.current.suspended || down.current?.moved) { paintJob.current = null; return; }
    const surface = canvas.current, holder = container.current;
    const ctx = surface?.getContext('2d', { alpha: false });
    if (!surface || !holder || !ctx) { return; }
    const { width, height } = size();
    const ratio = Math.min(2, window.devicePixelRatio || 1, Math.sqrt(5000000 / (width * height)));
    const pixelsWide = Math.ceil(width * ratio), pixelsHigh = Math.ceil(height * ratio);
    // Continuous wheel input replaces stretched bitmaps with sharp, viewport-only drawing
    // once per animation frame; a complete staged paint follows when scrolling stops.
    if (wheelActive.current && scenery.current.nodes.length + scenery.current.edges.length >= 384
      && typeof window.requestAnimationFrame === 'function') {
      paintJob.current = null;
      if (surface.width !== pixelsWide || surface.height !== pixelsHigh) {
        surface.width = pixelsWide; surface.height = pixelsHigh;
      }
      renderer.paintPreview(ctx, scenery.current, view, latest.current, width, height, ratio);
      paintedView.current = { x: view.x, y: view.y, zoom: view.zoom };
      syncBitmapCamera();
      return;
    }
    if (scenery.current.nodes.length + scenery.current.edges.length < 384
      || typeof window.requestAnimationFrame !== 'function') {
      paintJob.current = null;
      if (surface.width !== pixelsWide || surface.height !== pixelsHigh) {
        surface.width = pixelsWide; surface.height = pixelsHigh;
      }
      renderer.paint(ctx, scenery.current, view, latest.current, width, height, ratio);
      paintedView.current = { x: view.x, y: view.y, zoom: view.zoom };
      syncBitmapCamera();
      return;
    }
    if (!paintJob.current || paintJob.current.version !== paintVersion.current) {
      const hidden = document.createElement('canvas');
      hidden.width = pixelsWide; hidden.height = pixelsHigh;
      const hiddenCtx = hidden.getContext('2d', { alpha: false });
      if (!hiddenCtx) {
        if (surface.width !== pixelsWide || surface.height !== pixelsHigh) {
          surface.width = pixelsWide; surface.height = pixelsHigh;
        }
        renderer.paint(ctx, scenery.current, view, latest.current, width, height, ratio);
        paintedView.current = { x: view.x, y: view.y, zoom: view.zoom };
        syncBitmapCamera();
        return;
      }
      const viewport = new GraphViewport();
      viewport.x = view.x; viewport.y = view.y;
      viewport.zoom = view.zoom; viewport.fitting = view.fitting;
      paintJob.current = {
        version: paintVersion.current, surface: hidden, viewport,
        iterator: renderer.paintChunks(hiddenCtx, scenery.current, viewport, latest.current, width, height, ratio),
      };
    }
    const job = paintJob.current;
    if (!job.iterator.next().done) { schedulePaint(); return; }
    paintJob.current = null;
    // Show only a complete frame; keep the old bitmap visible while building.
    if (surface.width !== pixelsWide || surface.height !== pixelsHigh) {
      surface.width = pixelsWide; surface.height = pixelsHigh;
    }
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.drawImage(job.surface, 0, 0);
    paintedView.current = { x: job.viewport.x, y: job.viewport.y, zoom: job.viewport.zoom };
    syncBitmapCamera();
  };
  const fit = useCallback(() => {
    const { width, height } = size();
    const fitted = fitting(width, height);
    view.x = fitted.x; view.y = fitted.y; view.zoom = fitted.zoom; view.fitting = true;
    syncCamera(); syncBitmapCamera(); queuePaint();
  }, [view, queuePaint, size, fitting, syncCamera, syncBitmapCamera]);
  const center = useCallback((address: string) => {
    const point = retained.current.byAddress.get(address);
    if (!point) { return; }
    const { width, height } = size(); view.center(point, width, height); syncCamera(); syncBitmapCamera(); queuePaint();
  }, [view, queuePaint, size, syncCamera, syncBitmapCamera]);
  useImperativeHandle(externalRef, () => ({ center, fit }), [center, fit]);
  useEffect(() => {
    if (props.suspended) {
      if (frame.current !== null) { window.cancelAnimationFrame(frame.current); frame.current = null; }
      if (wheelFinish.current !== null) { window.clearTimeout(wheelFinish.current); wheelFinish.current = null; }
      wheelActive.current = false;
      paintJob.current = null;
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
      if (wheelFinish.current !== null) { window.clearTimeout(wheelFinish.current); wheelFinish.current = null; }
      wheelActive.current = false;
      paintJob.current = null;
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
          if (press.moved) {
            // Only the last completed bitmap follows the pointer; redraw once at drag end.
            if (paintJob.current) { paintVersion.current++; paintJob.current = null; }
            if (frame.current !== null) {
              window.cancelAnimationFrame(frame.current); frame.current = null;
            }
            view.pan(press.panX + dx, press.panY + dy);
            setTooltip(null); syncCamera(); syncBitmapCamera();
          }
          return;
        }
        const node = hit(event.clientX, event.clientY), bounds = event.currentTarget.getBoundingClientRect();
        setTooltip(node ? { address: node.address, x: event.clientX - bounds.left, y: event.clientY - bounds.top } : null);
      }}
      onPointerLeave={() => setTooltip(null)}
      onPointerUp={(event) => {
        const press = down.current; down.current = null;
        if (!press) { return; }
        if (press.moved) { queuePaint(); return; }
        const node = hit(event.clientX, event.clientY); if (node) { latest.current.onSelect(node.address); }
      }}
      onPointerCancel={() => { const moved = down.current?.moved; down.current = null; setTooltip(null); if (moved) { queuePaint(); } }}
      onWheel={(event) => {
        event.preventDefault(); setTooltip(null);
        const bounds = event.currentTarget.getBoundingClientRect(), dimensions = size();
        const zoomLimit = fitting(dimensions.width, dimensions.height).zoom;
        view.zoomAt(event.clientX - bounds.left, event.clientY - bounds.top, event.deltaY, zoomLimit);
        syncCamera(); syncBitmapCamera();
        wheelActive.current = true;
        paintVersion.current++;
        paintJob.current = null;
        schedulePaint();
        if (wheelFinish.current !== null) { window.clearTimeout(wheelFinish.current); }
        wheelFinish.current = window.setTimeout(() => {
          wheelFinish.current = null;
          wheelActive.current = false;
          queuePaint();
        }, 110);
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
