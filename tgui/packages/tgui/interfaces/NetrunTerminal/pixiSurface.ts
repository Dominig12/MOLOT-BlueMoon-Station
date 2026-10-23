import type { Application, Container, Graphics, Text } from 'pixi.js';

import { layoutLabels } from './graphLabels';
import { GRAPH_TILE } from './graphLayout';
import { markerColor, physicalPoint } from './graphRenderer';
import type { GraphBase, GraphOverlay } from './graphRenderer';
import type { GraphScene, PlacedNode } from './graphScene';
import type { NetEdge } from './types';
import { PixiActors } from './pixiActors';
import { clamp, GraphViewport } from './graphViewport';

/** Resource caps protect the embedded BYOND browser and integrated GPUs. */
export const PIXI_LIMITS = Object.freeze({
  maxNodes: 2000,
  maxEdges: 5000,
  maxZoneRuns: 4096,
  maxPixels: 2000000,
  maxFps: 30,
  maxLabels: 48,
});

export type PixiCamera = Pick<GraphViewport, 'x' | 'y' | 'zoom'>;
export type PixiSurface = {
  updateScene: (scene: GraphScene, base: GraphBase) => boolean;
  updateActors: (scene: GraphScene, overlay: GraphOverlay,
    dynamicEdges: NetEdge[], adjacency: Map<string, Set<string>>) => void;
  updateCamera: (camera: PixiCamera) => void;
  resize: (width: number, height: number) => boolean;
  destroy: () => void;
};

export const pixiWithinBudget = (nodes: number, edges: number, width: number, height: number, zones = 0) =>
  Number.isFinite(width) && Number.isFinite(height)
  && nodes >= 0 && nodes <= PIXI_LIMITS.maxNodes
  && edges >= 0 && edges <= PIXI_LIMITS.maxEdges
  && zones >= 0 && zones <= PIXI_LIMITS.maxZoneRuns
  && width > 0 && height > 0 && width * height <= PIXI_LIMITS.maxPixels;

/** Never allocates a throwaway WebGL context just to test compatibility. */
export const webglAvailable = () =>
  typeof window !== 'undefined' && typeof window.WebGL2RenderingContext !== 'undefined';

export const zoneRunCount = (base: GraphBase) =>
  (base.apcZones || []).reduce((sum, zone) => sum + zone.runs.length, 0);

const hex = (value: string | undefined, fallback: number) => {
  if (!value || !/^#[0-9a-f]{6}$/i.test(value)) { return fallback; }
  return Number.parseInt(value.slice(1), 16);
};
const edgeColor = (kind: string, online: boolean) => !online ? 0x24333e
  : kind === 'relay' ? 0x3fb8ad : kind === 'apc' ? 0x3d6d86 : 0x274a5f;
const captionFor = (node: PlacedNode, base: GraphBase) =>
  ['apc', 'gateway', 'relay'].includes(node.type)
    ? [base.gateways.get(node.network)?.code, node.sector?.replace('sector:', 'S'), node.name]
      .filter(Boolean).join(' · ')
    : node.name;

/**
 * Dedicated GPU base for NetRun. Input and gameplay effects remain in the
 * existing SVG ActorLayer. No individual Pixi display objects are made for
 * the nodes or edges; all shapes are batched into retained Graphics objects.
 *
 * init is lazy and ONLY called by GraphCanvas when the map is visible.
 */
export async function mountNetrunPixi(
  host: HTMLElement,
  width: number,
  height: number,
  onUnavailable?: () => void,
): Promise<PixiSurface | null> {
  if (!pixiWithinBudget(0, 0, width, height) || !webglAvailable()
    || typeof window.requestAnimationFrame !== 'function') { return null; }

  let library: typeof import('pixi.js');
  try { library = await import('pixi.js'); }
  catch { return null; }

  const { Application: App, Container: Group, Graphics: Shape, Text: PixiText } = library;
  const app: Application = new App();
  try {
    await app.init({
      width, height, preference: 'webgl', preferWebGLVersion: 2,
      powerPreference: 'low-power', autoStart: false, sharedTicker: false,
      antialias: false, autoDensity: false, resolution: 1,
      background: 0x081420, eventFeatures: {
        move: false, globalMove: false, click: false, wheel: false,
      },
    });
    app.stop();
  } catch {
    try { app.destroy({ removeView: true }, { children: true }); } catch { /* Partially initialized. */ }
    return null;
  }

  const grid: Graphics = new Shape();
  const world: Container = new Group();
  const zones: Graphics = new Shape();
  const anchors: Graphics = new Shape();
  const links: Graphics[] = Array.from({ length: 6 }, () => new Shape());
  const glyphs: Graphics = new Shape();
  const labelBackground: Graphics = new Shape();
  const labelLayer: Container = new Group();
  const actors = new PixiActors(library);
  world.addChild(zones, anchors, ...links, glyphs, actors.world);
  app.stage.addChild(grid, world, labelBackground, labelLayer);
  const status: Text = new PixiText({
    text: '', style: { fontFamily: 'monospace', fontSize: 11, fill: 0x8faebe },
  });
  app.stage.addChild(status);
  // Pixi draws stationary scenery; the TGUI SVG actor layer owns selections,
  // route animations, moving devices, events and all pointer interaction.
  const element = app.canvas;
  element.setAttribute('data-net-pixi', '');
  element.setAttribute('aria-hidden', 'true');
  Object.assign(element.style, {
    position: 'absolute', inset: '0', width: '100%', height: '100%',
    display: 'block', zIndex: '0', pointerEvents: 'none',
  });
  host.appendChild(element);

  let disposed = false, frame: number | null = null, lastFrame = -Infinity;
  let slowFrames = 0, unavailableSignaled = false;
  const reportUnavailable = () => {
    if (disposed || unavailableSignaled) { return; }
    unavailableSignaled = true;
    onUnavailable?.();
  };
  let currentWidth = width, currentHeight = height, geometryDirty = false, viewDirty = true;
  let sceneRef: GraphScene | null = null, liveSceneRef: GraphScene | null = null;
  let baseRef: GraphBase | null = null;
  let camera: PixiCamera = { x: 0, y: 0, zoom: 1 };
  const view = new GraphViewport();
  const labels: Text[] = [];

  const paintView = () => {
    view.x = camera.x; view.y = camera.y; view.zoom = camera.zoom;
    grid.clear();
    const step = clamp(Math.pow(2, Math.ceil(Math.log2(80 / camera.zoom))) * camera.zoom, 32, 240);
    for (let x = ((camera.x % step) + step) % step; x < currentWidth; x += step) {
      grid.moveTo(x, 0).lineTo(x, currentHeight);
    }
    for (let y = ((camera.y % step) + step) % step; y < currentHeight; y += step) {
      grid.moveTo(0, y).lineTo(currentWidth, y);
    }
    grid.stroke({ color: 0x468298, alpha: .09, width: 1 });
    world.position.set(camera.x, camera.y);
    world.scale.set(camera.zoom);
    status.text = `Север ↑ · ${sceneRef?.nodes.length ?? 0} узлов · ${Math.round(camera.zoom * 100)}%`;
    status.position.set(12, Math.max(0, currentHeight - 22));
    labelBackground.clear();
    if (!sceneRef || !baseRef || camera.zoom < .5) {
      for (const label of labels) { label.visible = false; }
      return;
    }
    const left = -camera.x / camera.zoom, top = -camera.y / camera.zoom;
    const right = (currentWidth - camera.x) / camera.zoom, bottom = (currentHeight - camera.y) / camera.zoom;
    // Labels have a hard upper bound: their texture uploads, not vector shapes,
    // are the expensive part of Pixi text rendering.
    const visibleStatic = sceneRef.visible(left - 32, top - 32, right + 32, bottom + 32)
      .filter((node) => !node.dynamic);
    const visibleDynamic = liveSceneRef ? liveSceneRef.visible(left - 32, top - 32,
      right + 32, bottom + 32).filter((node) => !!node.dynamic) : [];
    const visible = [...visibleStatic, ...visibleDynamic];
    const placed = layoutLabels(visible, view, currentWidth, Math.max(0, currentHeight - 26),
      (text) => text.length * 6.6, () => 0, (node) => captionFor(node, baseRef!))
      .slice(0, PIXI_LIMITS.maxLabels);
    for (let index = 0; index < placed.length; index++) {
      const data = placed[index];
      let label = labels[index];
      if (!label) {
        label = new PixiText({ text: '', style: {
          fontFamily: 'monospace', fontSize: 11, fill: 0x99b2c1,
        } });
        labels.push(label);
        labelLayer.addChild(label);
      }
      if (label.text !== data.text) { label.text = data.text; }
      label.x = data.rect.left + 4;
      label.y = data.rect.top + 2;
      label.visible = true;
      labelBackground.rect(data.rect.left, data.rect.top,
        data.rect.right - data.rect.left, 19).fill({ color: 0x0b1d28 });
    }
    for (let index = placed.length; index < labels.length; index++) { labels[index].visible = false; }
  };

  const paintGeometry = () => {
    if (!sceneRef || !baseRef) { return; }
    zones.clear(); anchors.clear(); glyphs.clear();
    for (const link of links) { link.clear(); }
    for (const area of baseRef.apcZones || []) {
      for (const run of area.runs) {
        zones.rect((run.x - .5) * GRAPH_TILE, -(run.y + .5) * GRAPH_TILE,
          run.width * GRAPH_TILE, GRAPH_TILE).fill({ color: 0x4095bc, alpha: .16 });
      }
    }
    for (const node of sceneRef.nodes) {
      const anchor = physicalPoint(node);
      if (anchor.px !== node.px || anchor.py !== node.py) {
        anchors.moveTo(anchor.px, anchor.py).lineTo(node.px, node.py);
      }
    }
    anchors.stroke({ color: 0x75a3b4, width: 1, alpha: .45 });

    // Group strokes by their static style, never one DrawCall per connection.
    for (const edge of sceneRef.edges) {
      const a = sceneRef.byAddress.get(edge.from), b = sceneRef.byAddress.get(edge.to);
      if (!a || !b) { continue; }
      const group = (edge.kind === 'endpoint' ? 0 : edge.kind === 'apc' ? 1 : 2)
        + (edge.online === false ? 3 : 0);
      const from = physicalPoint(a), to = physicalPoint(b);
      links[group].moveTo(from.px, from.py).lineTo(to.px, to.py);
    }
    for (let i = 0; i < links.length; i++) {
      const kind = ['endpoint', 'apc', 'relay'][i % 3], online = i < 3;
      links[i].stroke({ width: kind === 'endpoint' ? 1 : 1.5,
        color: edgeColor(kind, online), alpha: kind === 'endpoint' ? .72 : 1 });
    }

    const glyphScale = Math.min(6, Math.max(1, Math.ceil(.5 / Math.max(camera.zoom, .08))));
    for (const node of sceneRef.nodes) {
      if (node.dynamic) { continue; } // Drawn by PixiActors instead.
      const border = hex(baseRef.gateways.get(node.network)?.color, 0x527287);
      const fill = hex(markerColor(node), 0x678698);
      const x = node.px, y = node.py;
      if (node.type === 'apc') {
        glyphs.rect(x - 11 * glyphScale, y - 11 * glyphScale, 22 * glyphScale, 22 * glyphScale);
      } else if (node.type === 'gateway' || node.type === 'relay') {
        for (let index = 0; index < 6; index++) {
          const angle = index * Math.PI / 3;
          if (index === 0) { glyphs.moveTo(x + Math.cos(angle) * 14 * glyphScale, y + Math.sin(angle) * 14 * glyphScale); }
          else { glyphs.lineTo(x + Math.cos(angle) * 14 * glyphScale, y + Math.sin(angle) * 14 * glyphScale); }
        }
        glyphs.closePath();
      } else if (node.type === 'server' || node.type === 'terminal') {
        glyphs.moveTo(x, y - 12 * glyphScale).lineTo(x + 12 * glyphScale, y)
          .lineTo(x, y + 12 * glyphScale).lineTo(x - 12 * glyphScale, y).closePath();
      } else { glyphs.circle(x, y, 8 * glyphScale); }
      glyphs.fill({ color: fill }).stroke({ width: 1.5, color: border });
    }
  };

  const requestRender = () => {
    if (disposed || frame !== null || document.hidden) { return; }
    const tick = (now: number) => {
      frame = null;
      if (disposed || document.hidden) { return; }
      if (now - lastFrame < 1000 / PIXI_LIMITS.maxFps) {
        frame = window.requestAnimationFrame(tick);
        return;
      }
      try {
        const began = performance.now();
        if (geometryDirty) { paintGeometry(); geometryDirty = false; viewDirty = true; }
        if (viewDirty) { paintView(); viewDirty = false; }
        app.renderer.render({ container: app.stage });
        lastFrame = now;
        // Slow integrated GPUs and software WebGL fall back automatically
        // instead of locking the BYOND browser during prolonged interaction.
        if (performance.now() - began > 70) { slowFrames++; }
        else { slowFrames = Math.max(0, slowFrames - 1); }
        if (slowFrames >= 5) { reportUnavailable(); }
      } catch {
        reportUnavailable();
      }
    };
    frame = window.requestAnimationFrame(tick);
  };
  const onLost = (event: Event) => { event.preventDefault(); reportUnavailable(); };
  const onVisible = () => { if (!document.hidden) { requestRender(); } };
  element.addEventListener('webglcontextlost', onLost);
  document.addEventListener('visibilitychange', onVisible);

  return {
    updateScene(scene, base) {
      if (disposed || !pixiWithinBudget(scene.nodes.length, scene.edges.length,
        currentWidth, currentHeight, zoneRunCount(base))) { return false; }
      if (scene !== sceneRef || base.gateways !== baseRef?.gateways || base.apcZones !== baseRef?.apcZones) {
        sceneRef = scene; baseRef = base; geometryDirty = true; requestRender();
      }
      return true;
    },
    updateActors(scene, overlay, dynamicEdges, adjacency) {
      if (disposed) { return; }
      if (actors.update(scene, overlay, dynamicEdges, adjacency)) {
        liveSceneRef = scene;
        viewDirty = true; // Screen-space labels follow movable devices.
        requestRender();
      }
    },
    updateCamera(next) {
      if (disposed || (camera.x === next.x && camera.y === next.y && camera.zoom === next.zoom)) { return; }
      if (camera.zoom !== next.zoom) {
        actors.setZoom(next.zoom);
        // The world-space glyph size adapts when zoomed far out; pan never
        // triggers this geometry update.
        const prevGlyph = Math.min(6, Math.max(1, Math.ceil(.5 / Math.max(camera.zoom, .08))));
        const nextGlyph = Math.min(6, Math.max(1, Math.ceil(.5 / Math.max(next.zoom, .08))));
        if (prevGlyph !== nextGlyph) { geometryDirty = true; }
      }
      camera = { x: next.x, y: next.y, zoom: next.zoom };
      viewDirty = true;
      requestRender();
    },
    resize(nextWidth, nextHeight) {
      if (disposed || !pixiWithinBudget(0, 0, nextWidth, nextHeight)) { return false; }
      if (currentWidth !== nextWidth || currentHeight !== nextHeight) {
        currentWidth = nextWidth; currentHeight = nextHeight;
        app.renderer.resize(nextWidth, nextHeight);
        viewDirty = true; requestRender();
      }
      return true;
    },
    destroy() {
      if (disposed) { return; }
      disposed = true;
      if (frame !== null) { window.cancelAnimationFrame(frame); frame = null; }
      document.removeEventListener('visibilitychange', onVisible);
      element.removeEventListener('webglcontextlost', onLost);
      try { app.stop(); app.destroy({ removeView: true }, { children: true, texture: true, textureSource: true }); }
      catch { /* Context loss must not block DOM cleanup. */ }
      element.remove();
    },
  };
}
