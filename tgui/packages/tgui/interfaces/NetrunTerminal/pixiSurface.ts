import type { Application, Container, Graphics } from 'pixi.js';

import type { GraphScene } from './graphScene';
import type { GraphViewport } from './graphViewport';

/**
 * Opt-in WebGL renderer for NetRun.
 *
 * Importing this module does NOT load pixi.js or create a GPU context.
 * Use mountNetrunPixi only when explicitly selecting a GPU-backed view.
 * Canvas GraphRenderer remains the safe default for BYOND/CEF.
 */
export const PIXI_LIMITS = Object.freeze({
  maxNodes: 2000,
  maxEdges: 5000,
  maxPixels: 2000000,
  maxFps: 30,
});

export type PixiCamera = Pick<GraphViewport, 'x' | 'y' | 'zoom'>;
export type PixiSurface = {
  /** False means the caller must keep using its Canvas renderer. */
  updateScene: (scene: GraphScene) => boolean;
  updateCamera: (camera: PixiCamera) => void;
  resize: (width: number, height: number) => boolean;
  destroy: () => void;
};

/** A deterministic budget check before allocating WebGL resources. */
export const pixiWithinBudget = (nodes: number, edges: number, width: number, height: number) =>
  nodes >= 0 && nodes <= PIXI_LIMITS.maxNodes
  && edges >= 0 && edges <= PIXI_LIMITS.maxEdges
  && width > 0 && height > 0 && width * height <= PIXI_LIMITS.maxPixels;

export const webglAvailable = () => {
  if (typeof document === 'undefined') { return false; }
  try {
    // Do not import Pixi merely to test browser capability.
    return !!document.createElement('canvas').getContext('webgl2', {
      failIfMajorPerformanceCaveat: true,
      powerPreference: 'low-power',
    });
  } catch { return false; }
};

const nodeColor = (access: number, online: boolean) =>
  !online ? 0x607589 : access >= 3 ? 0x5bdab1 : access >= 2 ? 0x55cbe9 : 0x8298a8;

/**
 * One GPU canvas, two batched Graphics objects, no sprites per node,
 * textures, ticker, filters, particle systems or continuous animation loop.
 * Scene geometry is rebuilt only when its retained GraphScene changes.
 */
export async function mountNetrunPixi(
  host: HTMLElement,
  width: number,
  height: number,
  onUnavailable?: () => void,
): Promise<PixiSurface | null> {
  if (!pixiWithinBudget(0, 0, width, height)
    || typeof window.requestAnimationFrame !== 'function' || !webglAvailable()) { return null; }

  // Vite creates a separate chunk; the normal Canvas view never fetches it.
  let library: typeof import('pixi.js');
  try { library = await import('pixi.js'); }
  catch { onUnavailable?.(); return null; }
  const { Application: PixiApplication, Container: PixiContainer, Graphics: PixiGraphics } = library;
  const app: Application = new PixiApplication();
  try {
    await app.init({
      width, height,
      preference: 'webgl',
      preferWebGLVersion: 2,
      powerPreference: 'low-power',
      autoStart: false,
      sharedTicker: false,
      antialias: false,
      autoDensity: false,
      resolution: 1, // Hard cap GPU pixels regardless of OS/DPI scaling.
      background: 0x080f18,
      eventFeatures: { move: false, globalMove: false, click: false, wheel: false },
    });
    app.stop();
  } catch {
    try { app.destroy(true, { children: true }); } catch { /* CEF may have lost WebGL. */ }
    onUnavailable?.();
    return null;
  }

  const world: Container = new PixiContainer();
  const edges: Graphics = new PixiGraphics();
  const nodes: Graphics = new PixiGraphics();
  world.addChild(edges, nodes);
  app.stage.addChild(world);
  const view = app.canvas;
  view.setAttribute('data-net-pixi', '');
  view.setAttribute('aria-hidden', 'true');
  Object.assign(view.style, {
    display: 'block', position: 'absolute', inset: '0',
    width: '100%', height: '100%', pointerEvents: 'none',
  });
  host.appendChild(view);

  let disposed = false;
  let sceneRef: GraphScene | null = null;
  let frame: number | null = null;
  let lastFrame = -Infinity;
  let currentWidth = width, currentHeight = height;
  const requestRender = () => {
    if (disposed || frame !== null || document.hidden) { return; }
    const tick = (now: number) => {
      frame = null;
      if (disposed || document.hidden) { return; }
      if (now - lastFrame < 1000 / PIXI_LIMITS.maxFps) {
        frame = window.requestAnimationFrame(tick);
        return;
      }
      lastFrame = now;
      app.renderer.render(app.stage);
    };
    frame = window.requestAnimationFrame(tick);
  };

  const onLost = (event: Event) => {
    event.preventDefault();
    if (!disposed) { onUnavailable?.(); }
  };
  const onVisible = () => { if (!document.hidden) { requestRender(); } };
  view.addEventListener('webglcontextlost', onLost);
  document.addEventListener('visibilitychange', onVisible);

  return {
    updateScene(scene) {
      if (disposed || !pixiWithinBudget(scene.nodes.length, scene.edges.length, currentWidth, currentHeight)) {
        return false;
      }
      if (scene === sceneRef) { return true; }
      sceneRef = scene;
      edges.clear();
      nodes.clear();

      // Batch connections; no React elements or Pixi display object per edge.
      for (const edge of scene.edges) {
        const from = scene.byAddress.get(edge.from), to = scene.byAddress.get(edge.to);
        if (!from || !to) { continue; }
        edges.moveTo(from.px, from.py).lineTo(to.px, to.py);
      }
      edges.stroke({ color: 0x648ba9, alpha: .65, width: 1.5 });

      for (const node of scene.nodes) {
        const color = nodeColor(node.access, node.online);
        if (node.type === 'apc') {
          nodes.rect(node.px - 10, node.py - 10, 20, 20).fill({ color });
        } else if (node.type === 'server' || node.type === 'terminal') {
          nodes.moveTo(node.px, node.py - 12)
            .lineTo(node.px + 12, node.py).lineTo(node.px, node.py + 12)
            .lineTo(node.px - 12, node.py).closePath().fill({ color });
        } else {
          nodes.circle(node.px, node.py, 8).fill({ color });
        }
      }
      requestRender();
      return true;
    },
    updateCamera(camera) {
      if (disposed) { return; }
      world.position.set(camera.x, camera.y);
      world.scale.set(camera.zoom);
      requestRender();
    },
    resize(nextWidth, nextHeight) {
      if (disposed || !pixiWithinBudget(0, 0, nextWidth, nextHeight)) { return false; }
      if (nextWidth !== currentWidth || nextHeight !== currentHeight) {
        currentWidth = nextWidth;
        currentHeight = nextHeight;
        app.renderer.resize(nextWidth, nextHeight);
        requestRender();
      }
      return true;
    },
    destroy() {
      if (disposed) { return; }
      disposed = true;
      if (frame !== null) { window.cancelAnimationFrame(frame); }
      document.removeEventListener('visibilitychange', onVisible);
      view.removeEventListener('webglcontextlost', onLost);
      try { app.stop(); app.destroy(true, { children: true }); }
      catch { /* A lost context must not prevent DOM cleanup. */ }
      finally { view.remove(); }
    },
  };
}
