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

test('overview keeps ordinary camera glyphs small while enlarging only LAN outlines', () => {
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
  expect(radii.some((radius) => radius > 19)).toBe(true); // LAN outline alone remains prominent.
});
