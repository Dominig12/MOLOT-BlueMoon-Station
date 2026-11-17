import {
  countActivityNodes,
  diffById,
  fitView,
  FLAG_APC,
  FLAG_BROKEN,
  FLAG_DEVICE,
  FLAG_RADIO,
  FLAG_UNPOWERED,
  isOffline,
  kindOf,
  linkId,
  MAX_NODES,
  nearestNode,
  parseView,
  sameNode,
  screenToWorld,
  toWorld,
  zoomAt,
} from './model';

describe('parseView', () => {
  test('keeps valid rows and drops malformed rows and dangling links', () => {
    const view = parseView({
      nodes: [['1', 10, 20, FLAG_APC], ['2', 11, 20, FLAG_DEVICE], ['bad'], [3, 1, 1, 0], null],
      edges: [['1', '2'], ['1', '9'], ['x']],
      radio: [['2', '1']],
    });
    expect([...view.nodes.keys()]).toEqual(['1', '2']);
    expect([...view.links.keys()].sort()).toEqual([linkId('1', '2', true), linkId('1', '2', false)].sort());
    expect(view.links.get(linkId('2', '1', true))?.radio).toBe(true);
  });

  test('keeps silent wired links apart from live ones', () => {
    const view = parseView({
      nodes: [['1', 10, 20, FLAG_APC | FLAG_UNPOWERED], ['2', 11, 20, FLAG_DEVICE], ['3', 12, 20, FLAG_APC]],
      edges: [['2', '3']],
      down: [['2', '1'], ['1', '3'], ['1', '9']],
    });
    const silent = [...view.links.values()].filter(link => link.down);
    expect(silent.map(link => link.id).sort()).toEqual([linkId('1', '2', false, true), linkId('1', '3', false, true)].sort());
    expect(silent.every(link => !link.radio)).toBe(true);
    expect(view.links.get(linkId('2', '3', false))?.down).toBe(false);
  });

  test('caps the node count whatever the server sends', () => {
    const nodes = Array.from({ length: MAX_NODES + 10 }, (_, index) => [String(index), index, 0, 0]);
    expect(parseView({ nodes }).nodes.size).toBe(MAX_NODES);
  });

  test('classifies flags', () => {
    expect(kindOf(FLAG_APC)).toBe('apc');
    expect(kindOf(FLAG_DEVICE | FLAG_RADIO)).toBe('device');
    expect(kindOf(0)).toBe('node');
    expect(isOffline(FLAG_APC | FLAG_UNPOWERED)).toBe(true);
    expect(isOffline(FLAG_DEVICE | FLAG_BROKEN)).toBe(true);
    expect(isOffline(FLAG_APC | FLAG_DEVICE | FLAG_RADIO)).toBe(false);
  });
});

describe('diffById', () => {
  test('reports added, changed and removed entries and leaves the rest alone', () => {
    const before = parseView({ nodes: [['1', 1, 1, 0], ['2', 2, 2, 0], ['3', 3, 3, 0]] }).nodes;
    const after = parseView({ nodes: [['1', 1, 1, 0], ['2', 5, 2, 0], ['4', 4, 4, 0]] }).nodes;
    const delta = diffById(before, after, sameNode);
    expect(delta.added.map(node => node.id)).toEqual(['4']);
    expect(delta.changed.map(node => node.id)).toEqual(['2']);
    expect(delta.removed).toEqual(['3']);
  });
});

describe('viewport', () => {
  test('zoom keeps the world point under the cursor', () => {
    const view = { x: 30, y: -40, scale: 1.5 };
    const before = screenToWorld(view, 200, 120);
    const zoomed = zoomAt(view, 2, 200, 120);
    const after = screenToWorld(zoomed, 200, 120);
    expect(zoomed.scale).toBe(3);
    expect(after.x).toBeCloseTo(before.x);
    expect(after.y).toBeCloseTo(before.y);
  });

  test('zoom is clamped', () => {
    expect(zoomAt({ x: 0, y: 0, scale: 1 }, 1000, 0, 0).scale).toBe(8);
    expect(zoomAt({ x: 0, y: 0, scale: 1 }, 0.0001, 0, 0).scale).toBe(0.05);
  });

  test('fit centers the nodes and keeps an empty view unchanged', () => {
    const nodes = [...parseView({ nodes: [['1', 10, 10, 0], ['2', 30, 20, 0]] }).nodes.values()];
    const view = fitView(nodes, 400, 300, { x: 0, y: 0, scale: 1 });
    const center = toWorld({ x: 20, y: 15 });
    expect(center.x * view.scale + view.x).toBeCloseTo(200);
    expect(center.y * view.scale + view.y).toBeCloseTo(150);
    const current = { x: 5, y: 6, scale: 2 };
    expect(fitView([], 400, 300, current)).toBe(current);
  });

  test('hit testing finds the nearest node inside the radius only', () => {
    const nodes = [...parseView({ nodes: [['1', 10, 10, 0], ['2', 12, 10, 0]] }).nodes.values()];
    const point = toWorld({ x: 12, y: 10 });
    expect(nearestNode(nodes, point.x + 1, point.y, 4)?.id).toBe('2');
    expect(nearestNode(nodes, point.x + 100, point.y, 4)).toBeNull();
  });
});

describe('countActivityNodes', () => {
  test('counts events per node and ignores empty ones', () => {
    expect(countActivityNodes([
      { node: '2' },
      { node: '2' },
      { node: '3' },
      {},
    ])).toEqual({ '2': 2, '3': 1 });
  });

  test('returns no marks for an empty history', () => {
    expect(countActivityNodes([])).toEqual({});
  });
});