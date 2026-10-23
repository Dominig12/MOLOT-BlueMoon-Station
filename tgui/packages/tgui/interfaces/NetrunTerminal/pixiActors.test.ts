import { GraphOverlay } from './graphPresentation';
import { GraphScene, PlacedNode } from './graphScene';
import { PixiActors } from './pixiActors';
import { MockContainer, MockGraphics, mockPixi, resetPixiMock } from './testSupport/pixiLibraryMock';

const node = (address: string, px = 0, py = 0): PlacedNode => ({ address, name: address, type: 'camera',
  x: px, y: py, px, py, security: 1, access: 1, online: true, active: false, entities: 0, uplink: null });
const overlay = (extra: Partial<GraphOverlay> = {}): GraphOverlay => ({ selected: null, entityHost: null, jacked: null,
  gateways: new Map(), selectedRoute: [], waypointRoute: [], pingRoute: [], events: [], ...extra });
beforeEach(resetPixiMock);

test('keyed movement reuses geometry, interpolates hit targets, and settles without an idle tick', () => {
  const scene = new GraphScene(); scene.update([{ ...node('A'), dynamic: true }, { ...node('B', 200), dynamic: true, ice: 2 }], []);
  const layer = new PixiActors(mockPixi), state = overlay(), edges = [], adjacency = scene.adjacency;
  layer.update(scene, state, edges, adjacency, 0); layer.animate(200);
  const a = MockContainer.instances.find((entry) => entry.label === 'device:A');
  const b = MockContainer.instances.find((entry) => entry.label === 'device:B');
  const originalWrites = MockGraphics.graphics.map((entry) => entry.clears);
  const next = new GraphScene(); next.update([{ ...node('A', 96), dynamic: true }, scene.nodes[1]], []);
  layer.update(next, state, edges, adjacency, 200);
  expect(MockContainer.instances.filter((entry) => entry.label === 'device:A')).toHaveLength(1);
  expect(MockGraphics.graphics.map((entry) => entry.clears)).toEqual(originalWrites);
  expect(layer.animate(260)).toBe(true);
  expect(a.position.x).toBeGreaterThan(0); expect(a.position.x).toBeLessThan(96);
  expect(layer.hit({ px: a.position.x, py: 0 }, 1)?.address).toBe('A');
  expect(layer.animate(500)).toBe(false); expect(a.position.x).toBe(96); expect(b.position.x).toBe(200);
  layer.destroy(); expect(a.destroyed && b.destroyed).toBe(true);
});

test('all dynamic links and routes longer than 256 hops survive, including a crossing link', () => {
  const scene = new GraphScene();
  const nodes = Array.from({ length: 301 }, (_, i) => node(`N${i}`, i * 10));
  const edges = nodes.slice(1).map((entry, i) => ({ id: `e${i}`, from: nodes[i].address, to: entry.address, kind: 'apc' as const }));
  scene.update(nodes, edges);
  const dynamic = Array.from({ length: 6001 }, (_, i) => ({ id: `d${i}`, from: 'N0', to: 'N300', kind: 'endpoint' as const }));
  const layer = new PixiActors(mockPixi);
  layer.update(scene, overlay({ selectedRoute: nodes.map((entry) => entry.address) }), dynamic, scene.adjacency, 0);
  expect(MockContainer.instances.find((entry) => entry.label === 'moving-cables').children).toHaveLength(6001);
  layer.setViewport({ left: 1400, right: 1600, top: -10, bottom: 10 }, 1);
  expect(MockGraphics.graphics.find((entry) => entry.label === 'edge:d6000').visible).toBe(true);
  expect(MockGraphics.graphics.some((entry) => entry.calls.filter((call) => call.op === 'lineTo').length === 300)).toBe(true);
});

test('traffic follows real adjacency rather than drawing a fictional straight shortcut', () => {
  const scene = new GraphScene();
  scene.update([node('A'), node('B', 0, 100), node('C', 100, 100)], [
    { id: 'AB', from: 'A', to: 'B', kind: 'apc' }, { id: 'BC', from: 'B', to: 'C', kind: 'apc' },
  ]);
  const layer = new PixiActors(mockPixi);
  layer.update(scene, overlay({ selectedRoute: ['A', 'C'], events: [{ kind: 'intrusion', from: 'A', to: 'C', age: 0 }] }), [], scene.adjacency, 0);
  expect(layer.animate(250)).toBe(true);
  const effects = MockGraphics.graphics.find((entry) => entry.label === 'traffic-and-ping');
  expect(effects.calls.filter((call) => call.op === 'circle').some((call) => call.args[0] === 0 && call.args[1] === 50)).toBe(true);
  expect(layer.animate(4001)).toBe(false);
  const disconnected = new GraphScene(); disconnected.update(scene.nodes, [scene.edges[0], { ...scene.edges[1], online: false }]);
  layer.update(disconnected, overlay({ events: [{ kind: 'intrusion', from: 'A', to: 'C', age: 0 }] }), [], disconnected.adjacency, 5000);
  layer.animate(5250);
  expect(effects.calls.filter((call) => call.op === 'circle')).toHaveLength(1); // Arrival marker, no packet through the broken link.
});

test('reduced motion snaps devices and stops packet, fade and ping animation immediately', () => {
  const scene = new GraphScene(); scene.update([{ ...node('A'), dynamic: true }, node('B', 100)], [{ id: 'AB', from: 'A', to: 'B', kind: 'apc' }]);
  const layer = new PixiActors(mockPixi); layer.setReducedMotion(true);
  const state = overlay({ pingRoute: ['A', 'B'], events: [{ kind: 'trace', from: 'A', to: 'B', age: 0 }] });
  layer.update(scene, state, [], scene.adjacency, 0);
  expect(layer.animate(0)).toBe(false);
  const next = new GraphScene(); next.update([{ ...node('A', 96), dynamic: true }, node('B', 100)], scene.edges);
  layer.update(next, state, [], next.adjacency, 10); expect(layer.animate(10)).toBe(false);
  expect(layer.hit({ px: 96, py: 0 }, 1)?.address).toBe('A');
});

test('zoomed-out Pixi actors keep device bodies small and enlarge ICE/entity rings only', () => {
  const scene = new GraphScene(); scene.update([
    { ...node('CAM'), dynamic: true },
    { ...node('ICE', 100), dynamic: true, ice: 2, entities: 1 },
  ], []);
  const layer = new PixiActors(mockPixi);
  layer.update(scene, overlay(), [], scene.adjacency, 0);
  layer.setViewport({ left: -100, right: 300, top: -100, bottom: 100 }, .2);
  const radii = MockGraphics.graphics.flatMap((graphic) => graphic.calls
    .filter((call) => call.op === 'circle').map((call) => call.args[2]));
  expect(radii).toContain(8);
  expect(radii.some((radius) => radius >= 46)).toBe(true);
});
