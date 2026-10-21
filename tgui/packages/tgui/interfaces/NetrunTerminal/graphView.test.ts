import { intersects, layoutLabels } from './graphLabels';
import { GRAPH_GAP, GRAPH_GLYPH_RADIUS, GraphLayout } from './graphLayout';
import { GraphScene, PlacedNode } from './graphScene';
import { GraphViewport } from './graphViewport';
import { NetEdge } from './types';

const node = (address: string, px = 0, py = 0): PlacedNode => ({
  address, name: `Узел ${address}`, type: 'camera', x: 0, y: 0, security: 1,
  online: true, access: 1, entities: 0, active: false, uplink: null, px, py,
});

test('6000 individual markers keep non-overlapping world bounds and fit a complete overview', () => {
  const layout = new GraphLayout();
  const apc = { address: 'APC', type: 'apc', uplink: null };
  const clients = Array.from({ length: 6000 }, (_, i) => ({ address: `N-${i}`, type: 'camera', uplink: 'APC' }));
  const edges: NetEdge[] = clients.map((client) => ({ id: client.address, from: 'APC', to: client.address, kind: 'endpoint' }));
  const points = layout.update([apc, ...clients], edges);
  expect(points.size).toBe(6001);
  const cells = new Set<string>();
  for (const point of points.values()) {
    expect(Math.abs(point.px % GRAPH_GAP)).toBe(0);
    expect(Math.abs(point.py % GRAPH_GAP)).toBe(0);
    const key = `${point.px},${point.py}`;
    expect(cells.has(key)).toBe(false); cells.add(key);
  }
  expect(GRAPH_GLYPH_RADIUS * 2).toBeLessThan(GRAPH_GAP);
  const camera = new GraphViewport(); camera.fit(points.values(), 280, 180);
  expect(camera.zoom).toBeLessThan(.08);
  for (const point of points.values()) {
    const screen = camera.project(point), radius = GRAPH_GLYPH_RADIUS * camera.zoom;
    expect(screen.px - radius).toBeGreaterThanOrEqual(0);
    expect(screen.py - radius).toBeGreaterThanOrEqual(0);
    expect(screen.px + radius).toBeLessThanOrEqual(280);
    expect(screen.py + radius).toBeLessThanOrEqual(180);
  }
});

test('manual camera survives data changes and wheel zoom keeps its cursor anchor', () => {
  const camera = new GraphViewport(); camera.fit([node('a'), node('b', 100000, -20000)], 720, 480);
  const fitZoom = camera.zoom;
  const point = camera.unproject(250, 190);
  camera.zoomAt(250, 190, -100, fitZoom);
  expect(camera.project(point).px).toBeCloseTo(250);
  expect(camera.project(point).py).toBeCloseTo(190);
  expect(camera.fitting).toBe(false);
  camera.pan(30, 50);
  expect(camera.x).toBe(30); expect(camera.y).toBe(50);
  camera.fit([node('a')], 600, 300);
  expect(camera.fitting).toBe(true);
  expect(camera.project(node('a'))).toEqual({ px: 300, py: 150 });
});

test('hit boxes may overlap at overview scale, but nearest selection is deterministic', () => {
  const scene = new GraphScene(); scene.update([node('B', 96), node('A')], []);
  expect(scene.hit({ px: 48, py: 0 }, .08).address).toBe('A');
  expect(scene.hit({ px: 90, py: 0 }, .08).address).toBe('B');
  scene.update([node('B', 96)], []);
  expect(scene.byAddress.has('A')).toBe(false);
  expect(scene.hit({ px: -1000, py: 0 }, .08)).toBeNull();
});

test('actual label rectangles never overlap other labels or marker bounds, even for selected nodes', () => {
  const nodes = Array.from({ length: 100 }, (_, i) => ({ ...node(`n-${i}`, (i % 10) * 96, Math.floor(i / 10) * 96), name: 'Очень длинное название устройства станции' }));
  const camera = new GraphViewport(); camera.zoom = .7; camera.x = 40; camera.y = 40;
  const labels = layoutLabels(nodes, camera, 720, 720, (text) => text.length * 7, (entry) => entry.address === 'n-0' ? 5 : 0);
  expect(labels.length).toBeGreaterThan(0);
  for (let i = 0; i < labels.length; i++) {
    for (const other of labels.slice(i + 1)) { expect(intersects(labels[i].rect, other.rect)).toBe(false); }
    for (const marker of nodes) {
      const point = camera.project(marker), radius = GRAPH_GLYPH_RADIUS * camera.zoom;
      expect(intersects(labels[i].rect, { left: point.px - radius, right: point.px + radius, top: point.py - radius, bottom: point.py + radius })).toBe(false);
    }
  }
  camera.zoom = .05;
  expect(layoutLabels(nodes, camera, 720, 720, (text) => text.length * 7, () => 5)).toEqual([]);
});

test('malformed parent cycles and long endpoint chains stay finite and collision-free', () => {
  const nodes = Array.from({ length: 6000 }, (_, i) => ({ address: `N${i}`, type: 'implant', uplink: `N${(i + 1) % 6000}` }));
  const layout = new GraphLayout(); const points = layout.update(nodes, []);
  expect(points.size).toBe(6000);
  expect(new Set([...points.values()].map((point) => `${point.px},${point.py}`)).size).toBe(6000);
  const again = layout.update(nodes, []);
  for (const [address, point] of points) { expect(again.get(address)).toBe(point); }
});
