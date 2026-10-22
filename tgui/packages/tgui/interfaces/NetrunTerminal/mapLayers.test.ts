import { GraphLayout } from './graphLayout';
import { StaticMapProjection } from './mapLayers';
import { NetEdge, NetNode } from './types';

const node: NetNode = { address: 'APC', name: 'APC', type: 'apc', x: 1, y: 1, online: true,
  access: 1, security: 1, entities: 0, ice: 0, active: false, uplink: null };
const mobile: NetNode = { ...node, address: 'DECK', type: 'deck', dynamic: true, uplink: node.address };
const edge: NetEdge = { id: 'mobile', from: node.address, to: mobile.address, kind: 'endpoint' };

test('actor movement, activity, occupants and mobile connections retain the stationary scene', () => {
  const projection = new StaticMapProjection();
  const first = projection.update([node, mobile], [edge]);
  const moved = projection.update([{ ...node, entities: 2, ice: 1, active: true, can_hop: true },
    { ...mobile, x: 20, uplink: 'OTHER' }], [{ ...edge, from: 'OTHER' }]);
  expect(moved).toBe(first);
  expect(moved.nodes).toHaveLength(1);
  expect(moved.edges).toHaveLength(0);
  expect(moved.nodes[0]).toEqual(expect.objectContaining({ entities: 0, ice: 0, active: false }));
});

test('stationary status changes repaint without recomputing its geographic layout', () => {
  const projection = new StaticMapProjection();
  const first = projection.update([node], []);
  const offline = projection.update([{ ...node, online: false }], []);
  expect(offline).not.toBe(first);
  expect(offline.geometry).toBe(first.geometry);
  expect(offline.nodes[0].online).toBe(false);
});

test('stationary deletion frees its marker and links and advances geographic layout', () => {
  const projection = new StaticMapProjection();
  const peer = { ...node, address: 'PEER', x: 20 };
  const first = projection.update([node, peer], [{ ...edge, to: peer.address }]);
  const deleted = projection.update([peer], []);
  expect(deleted.geometry).toBeGreaterThan(first.geometry);
  expect(deleted.nodes.map((entry) => entry.address)).toEqual(['PEER']);
  expect(deleted.edges).toEqual([]);
});

test('an endpoint becoming mobile leaves the canvas while other stationary markers remain retained', () => {
  const projection = new StaticMapProjection();
  const peer = { ...node, address: 'PEER' };
  const first = projection.update([node, peer], []);
  const changed = projection.update([{ ...node, dynamic: true }, peer], []);
  expect(changed.nodes).toEqual([first.nodes[1]]);
  expect(changed.nodes[0]).toBe(first.nodes[1]);
});

test('server stationary generations retain the same scene across live snapshots', () => {
  const projection = new StaticMapProjection();
  const first = projection.update([node, mobile], [edge], 'sector:1:3');
  expect(projection.update([{ ...node, entities: 1 }, { ...mobile, x: 50 }], [edge], 'sector:1:3')).toBe(first);
  const removed = projection.update([mobile], [], 'sector:1:4');
  expect(removed.nodes).toEqual([]);
});

test('a moving endpoint reserves a separate marker slot without moving the stationary device', () => {
  const layout = new GraphLayout();
  const stationarySlot = '96,-96';
  const placed = layout.update([mobile], [], new Set([stationarySlot]));
  const point = placed.get(mobile.address);
  expect(`${point.px},${point.py}`).not.toBe(stationarySlot);
  const occupied = { ...mobile, entities: 2 };
  expect(layout.update([occupied], [], new Set([stationarySlot])).get(mobile.address)).toBe(point);
});
