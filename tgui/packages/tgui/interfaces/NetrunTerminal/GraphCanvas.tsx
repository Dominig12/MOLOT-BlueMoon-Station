/* eslint-disable react/no-unused-prop-types -- forwardRef accesses typed props through its retained render callbacks. */
import { forwardRef, memo, useCallback, useEffect, useImperativeHandle, useMemo, useRef, useState } from 'react';

import { GraphOverlay, GraphRenderer } from './graphRenderer';
import { GraphScene, PlacedNode } from './graphScene';
import { clamp, GraphViewport } from './graphViewport';
import { GraphPoint } from './mapLayout';
import { NetEdge, NODE_NAMES, THEME } from './types';

export type GraphCanvasHandle = { center: (address: string) => void; fit: () => void };
type Props = GraphOverlay & {
  nodes: PlacedNode[]; edges: NetEdge[]; positions: Map<string, GraphPoint>;
  focus: string | null; adjacency: Map<string, Set<string>>; onSelect: (address: string) => void;
};

/** React owns controls/lifecycle; scene, camera and renderer own their respective state. */
export const GraphCanvas = memo(forwardRef<GraphCanvasHandle, Props>((props, externalRef) => {
  const container = useRef<HTMLDivElement>(null), canvas = useRef<HTMLCanvasElement>(null);
  const [view] = useState(() => new GraphViewport());
  const [renderer] = useState(() => new GraphRenderer());
  const latest = useRef(props); latest.current = props;
  const frame = useRef<number | null>(null);
  const down = useRef<{ x: number; y: number; panX: number; panY: number; moved: boolean } | null>(null);
  const [tooltip, setTooltip] = useState<{ address: string; x: number; y: number } | null>(null);
  const scene = useMemo(() => {
    const value = new GraphScene(); value.update(props.nodes, props.edges); return value;
  }, [props.nodes, props.edges]);
  const retained = useRef(scene); retained.current = scene;
  const size = useCallback(() => ({ width: container.current?.clientWidth || 720, height: container.current?.clientHeight || 480 }), []);
  const paintRef = useRef<() => void>(() => {});
  const queuePaint = useCallback(() => {
    if (frame.current !== null) { return; }
    if (typeof window.requestAnimationFrame !== 'function') { paintRef.current(); return; }
    frame.current = window.requestAnimationFrame(() => { frame.current = null; paintRef.current(); });
  }, []);
  paintRef.current = () => {
    const surface = canvas.current, holder = container.current;
    const ctx = surface?.getContext('2d', { alpha: false });
    if (!surface || !holder || !ctx) { return; }
    const { width, height } = size();
    const ratio = Math.min(2, window.devicePixelRatio || 1, Math.sqrt(5000000 / (width * height)));
    if (surface.width !== Math.ceil(width * ratio) || surface.height !== Math.ceil(height * ratio)) {
      surface.width = Math.ceil(width * ratio); surface.height = Math.ceil(height * ratio);
    }
    const animating = renderer.paint(ctx, retained.current, view, latest.current, width, height, ratio, performance.now());
    // A finite presentation transition may schedule frames; an idle graph has no render loop.
    if (animating && typeof window.requestAnimationFrame === 'function') { queuePaint(); }
  };
  const fit = useCallback(() => {
    const { width, height } = size(); view.fit(retained.current.nodes, width, height); queuePaint();
  }, [view, queuePaint, size]);
  const center = useCallback((address: string) => {
    const point = retained.current.byAddress.get(address);
    if (!point) { return; }
    const { width, height } = size(); view.center(point, width, height); queuePaint();
  }, [view, queuePaint, size]);
  useImperativeHandle(externalRef, () => ({ center, fit }), [center, fit]);
  useEffect(() => {
    renderer.update(scene, props.events, performance.now());
    if (view.fitting && scene.nodes.length) { fit(); } else { queuePaint(); }
  }, [scene, props, renderer, view, fit, queuePaint]);
  useEffect(() => {
    if (tooltip && !scene.byAddress.has(tooltip.address)) { setTooltip(null); }
  }, [scene, tooltip]);
  useEffect(() => {
    const el = container.current;
    if (!el) { return; }
    const resized = () => { if (view.fitting) { fit(); } else { queuePaint(); } };
    const observer = typeof ResizeObserver === 'undefined' ? null : new ResizeObserver(resized);
    observer?.observe(el); window.addEventListener('resize', resized);
    return () => {
      observer?.disconnect(); window.removeEventListener('resize', resized);
      if (frame.current !== null) { window.cancelAnimationFrame(frame.current); frame.current = null; }
    };
  }, [view, fit, queuePaint]);
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
          if (press.moved) { view.pan(press.panX + dx, press.panY + dy); setTooltip(null); queuePaint(); }
          return;
        }
        const node = hit(event.clientX, event.clientY), bounds = event.currentTarget.getBoundingClientRect();
        setTooltip(node ? { address: node.address, x: event.clientX - bounds.left, y: event.clientY - bounds.top } : null);
      }}
      onPointerLeave={() => setTooltip(null)}
      onPointerUp={(event) => {
        const press = down.current; down.current = null;
        if (press && !press.moved) { const node = hit(event.clientX, event.clientY); if (node) { latest.current.onSelect(node.address); } }
      }}
      onPointerCancel={() => { down.current = null; setTooltip(null); }}
      onWheel={(event) => {
        event.preventDefault(); setTooltip(null);
        const bounds = event.currentTarget.getBoundingClientRect(), dimensions = size();
        const fitted = new GraphViewport(); fitted.fit(retained.current.nodes, dimensions.width, dimensions.height);
        view.zoomAt(event.clientX - bounds.left, event.clientY - bounds.top, event.deltaY, fitted.zoom); queuePaint();
      }}>
      <canvas ref={canvas} data-net-canvas aria-hidden="true" style={{ display: 'block', width: '100%', height: '100%' }} />
      {tooltip && tooltipNode && <div role="tooltip" style={{ position: 'absolute', zIndex: 5, left: clamp(tooltip.x + 14, 8, Math.max(8, size().width - 206)), top: clamp(tooltip.y + 12, 8, Math.max(8, size().height - 82)), width: '194px', padding: '8px 10px', pointerEvents: 'none', background: '#102531', border: '1px solid #316178', borderRadius: '6px', color: THEME.text, fontSize: '11px', boxShadow: '0 10px 25px rgba(0,0,0,.3)' }}>
        <div style={{ fontWeight: 700, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{tooltipNode.name}</div>
        <div style={{ opacity: .7, fontFamily: 'monospace' }}>{tooltipNode.address}</div>
        <div style={{ color: tooltipNode.online ? '#74d8b4' : '#ec8f91' }}>{NODE_NAMES[tooltipNode.type] || tooltipNode.type} · {tooltipNode.online ? 'В сети' : 'Не отвечает'}</div>
        <div>{tooltipNode.sector || ''}{tooltipNode.ice ? ` · ICE: ${tooltipNode.ice}` : ''}{tooltipNode.entities ? ` · процессы: ${tooltipNode.entities}` : ''}</div>
                                 </div>}
    </div>
  );
}));
