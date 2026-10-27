import { GraphScene, PlacedNode } from './graphScene';
import { PixiScenery } from './pixiScenery';
import { MockGraphics, mockPixi, resetPixiMock } from './testSupport/pixiLibraryMock';

const node = (address: string, px: number, py = 0): PlacedNode => ({ address, name: address, type: 'camera',
  x: px, y: py, px, py, security: 1, access: 1, online: true, active: false, entities: 0, uplink: null });
const finish = (layer: PixiScenery) => { for (let i = 0; i < 10000 && layer.advance(Infinity); i++) { /* bounded work slices */ } };
beforeEach(resetPixiMock);

test('large scenes retain every node, edge and APC run instead of rejecting GPU rendering', () => {
  const nodes = Array.from({ length: 6001 }, (_, i) => node(`N${i}`, (i % 100) * 96, Math.floor(i / 100) * 96));
  const edges = nodes.slice(1).map((entry, i) => ({ id: `E${i}`, from: nodes[i].address, to: entry.address, kind: 'apc' as const }));
  const scene = new GraphScene(); scene.update(nodes, edges);
  const runs = Array.from({ length: 5000 }, (_, i) => ({ x: i % 100, y: Math.floor(i / 100), width: 1 }));
  const layer = new PixiScenery(mockPixi); layer.queue(scene, { gateways: new Map(), apcZones: [{ address: 'N0', z: 1, runs }] });
  expect(layer.advance(0)).toBe(true); // A work slice yields before walking the entire topology.
  finish(layer);
  expect(MockGraphics.graphics.reduce((sum, graphic) => sum + graphic.calls.filter((call) => call.op === 'circle').length, 0)).toBe(6001);
  expect(MockGraphics.graphics.filter((graphic) => graphic.label.startsWith('1-edge:'))
    .reduce((sum, graphic) => sum + graphic.calls.filter((call) => call.op === 'lineTo').length, 0)).toBe(6000);
  expect(MockGraphics.graphics.reduce((sum, graphic) => sum + graphic.calls.filter((call) => call.op === 'rect').length, 0)).toBe(5000);
});

test('camera panning changes only culling and retains links crossing the viewport with offscreen endpoints', () => {
  const scene = new GraphScene(); scene.update([node('A', -1000), node('B', 1000)], [{ id: 'AB', from: 'A', to: 'B', kind: 'apc' }]);
  const layer = new PixiScenery(mockPixi); layer.queue(scene, { gateways: new Map() }); finish(layer);
  const clears = MockGraphics.graphics.map((graphic) => graphic.clears);
  layer.setViewport({ left: -20, right: 20, top: -20, bottom: 20 }, 1);
  expect(MockGraphics.graphics.find((graphic) => graphic.label.startsWith('1-edge:')).visible).toBe(true);
  expect(MockGraphics.graphics.filter((graphic) => graphic.label.startsWith('3-node:')).every((graphic) => !graphic.visible)).toBe(true);
  layer.setViewport({ left: 2000, right: 2100, top: -20, bottom: 20 }, 1);
  expect(MockGraphics.graphics.find((graphic) => graphic.label.startsWith('1-edge:')).visible).toBe(false);
  expect(MockGraphics.graphics.map((graphic) => graphic.clears)).toEqual(clears);
  layer.destroy(); expect(MockGraphics.graphics.every((graphic) => graphic.destroyed)).toBe(true);
});

test('unchanged spatial batches survive updates to another device', () => {
  const scene = new GraphScene(); scene.update([node('A', 0), node('B', 10000)], []);
  const base = { gateways: new Map() }, layer = new PixiScenery(mockPixi);
  layer.queue(scene, base); finish(layer);
  const retained = MockGraphics.graphics.find((graphic) => graphic.label.startsWith('3-node:13,'));
  const clears = retained.clears;
  const next = new GraphScene(); next.update([{ ...scene.nodes[0], online: false }, scene.nodes[1]], []);
  layer.queue(next, base); finish(layer);
  expect(retained.destroyed).toBe(false); expect(retained.clears).toBe(clears);
});

test('a LAN visibility change among 2000 nodes removes hidden hits and preserves unrelated chunks', () => {
  const nodes = Array.from({ length: 2000 }, (_, i) => node(`N${i}`, i * 96));
  const scene = new GraphScene(); scene.update(nodes, []);
  const base = { gateways: new Map() }, layer = new PixiScenery(mockPixi);
  layer.queue(scene, base); finish(layer);
  const distant = MockGraphics.graphics.find((graphic) => graphic.label.startsWith('3-node:200,'));
  const clears = distant.clears;
  const next = new GraphScene(); next.update([...nodes.slice(0, 20), ...nodes.slice(23), node('NEW', 21 * 96)], [], scene);
  expect(next.hit({ px: 20 * 96, py: 0 }, 1)).toBeNull();
  expect(next.hit({ px: 21 * 96, py: 0 }, 1).address).toBe('NEW');
  expect(scene.hit({ px: 20 * 96, py: 0 }, 1).address).toBe('N20');
  const hiddenChunk = MockGraphics.graphics.find((graphic) => graphic.label.startsWith('3-node:2,'));
  layer.suppressUndisclosed(next);
  expect(hiddenChunk.visible).toBe(false);
  layer.setViewport({ left: 0, right: 100000, top: -100, bottom: 100 }, 1);
  expect(hiddenChunk.visible).toBe(false);
  layer.queue(next, base); finish(layer);
  expect(distant.destroyed).toBe(false); expect(distant.clears).toBe(clears);
});

test('camera zoom leaves already-uploaded static graphics untouched', () => {
  const scene = new GraphScene(); scene.update([
    node('CAM', 0), { ...node('LAN', 200), type: 'gateway' },
  ], []);
  const layer = new PixiScenery(mockPixi);
  layer.queue(scene, { gateways: new Map() }); finish(layer);
  const clears = MockGraphics.graphics.map((graphic) => graphic.clears);
  layer.setViewport({ left: -250, right: 450, top: -250, bottom: 250 }, .2);
  finish(layer);
  layer.setViewport({ left: -250, right: 450, top: -250, bottom: 250 }, 1.8);
  finish(layer);
  expect(MockGraphics.graphics.map((graphic) => graphic.clears)).toEqual(clears);
});

test('lazy viewport chunks load only when visited and are reused when panning back', () => {
  const scene = new GraphScene();
  scene.update([node('A', 0), node('B', 10000)], []);
  const layer = new PixiScenery(mockPixi);
  layer.setViewport({ left: -100, right: 100, top: -100, bottom: 100 }, 1);
  layer.queue(scene, { gateways: new Map() }); finish(layer);
  const first = MockGraphics.graphics.filter((graphic) => graphic.label.startsWith('3-node:'));
  expect(first).toHaveLength(1);
  layer.setViewport({ left: 9900, right: 10100, top: -100, bottom: 100 }, 1); finish(layer);
  const loaded = MockGraphics.graphics.filter((graphic) => graphic.label.startsWith('3-node:'));
  expect(loaded).toHaveLength(2);
  const clears = loaded.map((graphic) => graphic.clears);
  layer.setViewport({ left: -100, right: 100, top: -100, bottom: 100 }, 1); finish(layer);
  expect(loaded.map((graphic) => graphic.clears)).toEqual(clears);
  expect(first[0].visible).toBe(true);
  expect(loaded[1].visible).toBe(false);
});
test('ordinary static glyphs retain their body size at overview zoom', () => {
  const scene = new GraphScene(); scene.update([
    node('CAM', 0), { ...node('LAN', 200), type: 'gateway' },
  ], []);
  const layer = new PixiScenery(mockPixi);
  layer.queue(scene, { gateways: new Map() });
  finish(layer);
  layer.setViewport({ left: -250, right: 450, top: -250, bottom: 250 }, .2);
  finish(layer);
  const radii = MockGraphics.graphics.flatMap((graphic) => graphic.calls
    .filter((call) => call.op === 'circle').map((call) => call.args[2]));
  expect(radii).toContain(8); // Body geometry is never inflated by camera zoom.
  expect(radii.every((radius) => Number(radius) <= 16)).toBe(true); // LAN outlines belong to the live layer.
});

test('moving and removing a device update its old and new chunks and incident cables only', () => {
  const scene = new GraphScene(); scene.update([node('A', 0), node('B', 10000), node('C', 20000)], [
    { id: 'AB', from: 'A', to: 'B', kind: 'apc' },
  ]);
  const layer = new PixiScenery(mockPixi), base = { gateways: new Map() };
  layer.queue(scene, base); finish(layer);
  const untouched = MockGraphics.graphics.find((graphic) => graphic.label.startsWith('3-node:26,'));
  const clears = untouched.clears;
  const next = new GraphScene(); next.update([{ ...scene.nodes[0], px: 2000 }, ...scene.nodes.slice(1)], scene.edges);
  layer.queue(next, base); finish(layer);
  expect(untouched.destroyed).toBe(false); expect(untouched.clears).toBe(clears);
  const cable = MockGraphics.graphics.find((graphic) => !graphic.destroyed && graphic.label.startsWith('1-edge:'));
  expect(cable.calls).toContainEqual({ op: 'moveTo', args: [2000, 0] });
  const removed = new GraphScene(); removed.update(scene.nodes.slice(1), []);
  layer.queue(removed, base); finish(layer);
  expect(MockGraphics.graphics.filter((graphic) => !graphic.destroyed && graphic.label.startsWith('1-edge:'))).toHaveLength(0);
  expect(untouched.destroyed).toBe(false); expect(untouched.clears).toBe(clears);
});

test('a superseded partial build cannot leave stale primitives or discard the committed scene', () => {
  const nodes = Array.from({ length: 512 }, (_, i) => node(`N${i}`, i * 96));
  const first = new GraphScene(); first.update(nodes, []);
  const layer = new PixiScenery(mockPixi), base = { gateways: new Map() };
  layer.queue(first, base); finish(layer);
  const discarded = new GraphScene(); discarded.update(nodes.map((entry) => ({ ...entry, online: false })), []);
  layer.queue(discarded, base); expect(layer.advance(0)).toBe(true);
  const final = new GraphScene(); final.update(nodes.slice(0, 1), []);
  layer.queue(final, base); finish(layer);
  const remaining = MockGraphics.graphics.filter((graphic) => !graphic.destroyed && graphic.label.startsWith('3-node:'));
  expect(remaining).toHaveLength(1);
  expect(remaining[0].calls.filter((call) => call.op === 'circle')).toHaveLength(1);
  expect(remaining[0].calls.find((call) => call.op === 'fill')?.args[0]).toEqual(expect.objectContaining({ alpha: .94 }));
});
