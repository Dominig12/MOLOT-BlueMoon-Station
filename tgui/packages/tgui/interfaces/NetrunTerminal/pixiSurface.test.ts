import { GraphOverlay } from './graphPresentation';
import { GraphScene, PlacedNode } from './graphScene';
import { framebufferResolution, mountNetrunPixi } from './pixiSurface';
import { MockApplication, resetPixiMock } from './testSupport/pixiLibraryMock';

jest.mock('pixi.js', () => jest.requireActual('./testSupport/pixiLibraryMock').mockPixi);

const node = (address: string, px = 0): PlacedNode => ({ address, name: address, type: 'camera', x: px, y: 0, px, py: 0,
  online: true, access: 1, active: false, entities: 0, security: 1, uplink: null });
const overlay = (): GraphOverlay => ({ selected: null, jacked: null, entityHost: null, gateways: new Map(),
  selectedRoute: [], waypointRoute: [], pingRoute: [], events: [] });
let frames: Map<number, FrameRequestCallback>, sequence: number, clock: number;
let lose: jest.Mock, context: WebGL2RenderingContext, getContext: jest.SpyInstance;
const flush = () => {
  for (let i = 0; frames.size && i < 1000; i++) {
    const pending = [...frames.values()]; frames.clear(); clock += 100;
    for (const frame of pending) { frame(clock); }
  }
  expect(frames.size).toBe(0);
};
beforeEach(() => {
  resetPixiMock(); frames = new Map(); sequence = 0; clock = 0;
  jest.spyOn(performance, 'now').mockImplementation(() => clock);
  Object.defineProperty(window, 'WebGL2RenderingContext', { value: function WebGL2() {}, configurable: true });
  Object.defineProperty(document, 'hidden', { value: false, configurable: true });
  jest.spyOn(window, 'requestAnimationFrame').mockImplementation((callback) => { const id = ++sequence; frames.set(id, callback); return id; });
  jest.spyOn(window, 'cancelAnimationFrame').mockImplementation((id) => { frames.delete(id); });
  lose = jest.fn(); context = { getExtension: () => ({ loseContext: lose }) } as unknown as WebGL2RenderingContext;
  getContext = jest.spyOn(HTMLCanvasElement.prototype, 'getContext').mockImplementation((kind: string) => {
    if (kind !== 'webgl2') { throw new Error(`Unexpected renderer: ${kind}`); }
    return context as never;
  });
});
afterEach(() => { jest.restoreAllMocks(); document.body.innerHTML = ''; });

test('framebuffer resolution adapts large displays without imposing topology limits', () => {
  expect(framebufferResolution(3000, 2000, 2)).toBeLessThan(1);
  expect(framebufferResolution(1280, 800, 1)).toBe(1);
});

test('aborting pending async init releases its context and never appends an orphan surface', async () => {
  let ready: () => void;
  MockApplication.pending = new Promise<void>((resolve) => { ready = resolve; });
  const host = document.createElement('div'), abort = new AbortController(); document.body.appendChild(host);
  const mounting = mountNetrunPixi(host, 800, 600, undefined, { signal: abort.signal });
  for (let i = 0; i < 5 && !MockApplication.instances.length; i++) { await Promise.resolve(); }
  expect(MockApplication.instances).toHaveLength(1);
  abort.abort(); ready(); expect(await mounting).toBeNull();
  expect(host.children).toHaveLength(0); expect(MockApplication.instances[0].destroys).toBe(1); expect(lose).toHaveBeenCalledTimes(1);
  expect(frames.size).toBe(0);
});

test('partial initialization failure cleans up renderer and context', async () => {
  MockApplication.rejectInit = true;
  const host = document.createElement('div');
  expect(await mountNetrunPixi(host, 800, 600)).toBeNull();
  expect(MockApplication.instances[0].destroys).toBe(1); expect(lose).toHaveBeenCalledTimes(1); expect(host.children).toHaveLength(0);
});

test('hidden workspaces keep the same context, defer updates, and resume without an idle render loop', async () => {
  const host = document.createElement('div'); document.body.appendChild(host);
  const surface = await mountNetrunPixi(host, 800, 600, undefined, { reducedMotion: true });
  const scene = new GraphScene(); scene.update([node('A')], []); const state = overlay();
  surface.updateScene(scene, state); surface.updateActors(scene, state, [], scene.adjacency); flush();
  const app = MockApplication.instances[0], before = app.renderer.render.mock.calls.length;
  surface.setSuspended(true); surface.updateCamera({ x: 30, y: 40, zoom: 2 });
  expect(frames.size).toBe(0); expect(app.renderer.render).toHaveBeenCalledTimes(before); expect(host.children).toHaveLength(1);
  surface.setSuspended(false); flush(); expect(MockApplication.instances).toHaveLength(1);
  expect(app.renderer.render.mock.calls.length).toBeGreaterThan(before);
  surface.destroy(); surface.destroy(); expect(app.destroys).toBe(1); expect(frames.size).toBe(0); expect(host.children).toHaveLength(0);
  expect(getContext.mock.calls.every(([kind]) => kind === 'webgl2')).toBe(true);
});

test('context loss pauses frames, restores retained objects and removes all listeners on destroy', async () => {
  const host = document.createElement('div'), status = jest.fn(), failed = jest.fn(); document.body.appendChild(host);
  const surface = await mountNetrunPixi(host, 800, 600, failed, { onStatus: status }); flush();
  const canvas = host.querySelector('canvas'), lost = new Event('webglcontextlost', { cancelable: true });
  canvas.dispatchEvent(lost); expect(lost.defaultPrevented).toBe(true); expect(status).toHaveBeenLastCalledWith('lost');
  surface.updateCamera({ x: 50, y: 40, zoom: 1 }); expect(frames.size).toBe(0);
  canvas.dispatchEvent(new Event('webglcontextrestored')); expect(status).toHaveBeenLastCalledWith('ready'); flush();
  expect(failed).not.toHaveBeenCalled(); surface.destroy();
  const calls = status.mock.calls.length; canvas.dispatchEvent(new Event('webglcontextrestored'));
  expect(status).toHaveBeenCalledTimes(calls); expect(frames.size).toBe(0);
});

test('finite live effects settle; reduced motion and document hiding cancel animation frames', async () => {
  const host = document.createElement('div'); document.body.appendChild(host);
  const surface = await mountNetrunPixi(host, 800, 600);
  const scene = new GraphScene(); scene.update([{ ...node('A'), dynamic: true }, node('B', 100)], [{ id: 'AB', from: 'A', to: 'B', kind: 'apc' }]);
  const state = { ...overlay(), pingRoute: ['A', 'B'], events: [{ kind: 'trace' as const, from: 'A', to: 'B', age: 0 }] };
  surface.updateScene(scene, state); surface.updateActors(scene, state, [], scene.adjacency);
  const initial = [...frames.values()]; frames.clear(); clock = 100; initial.forEach((callback) => callback(clock));
  expect(frames.size).toBeGreaterThan(0);
  Object.defineProperty(document, 'hidden', { value: true, configurable: true }); document.dispatchEvent(new Event('visibilitychange'));
  expect(frames.size).toBe(0);
  Object.defineProperty(document, 'hidden', { value: false, configurable: true }); document.dispatchEvent(new Event('visibilitychange'));
  flush(); surface.destroy();
});
