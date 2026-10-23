import { NetrunMapStream } from './mapStream';
import { NetMap, NetMapDelta, NetNode } from './types';

const node: NetNode = { address: 'APC', name: 'APC', type: 'apc', x: 1, y: 1, online: true,
  access: 1, security: 1, entities: 0, ice: 0, active: false, uplink: null };
const baseline = (overrides: Partial<NetMap> = {}): NetMap => ({ epoch: 'ui:one', full: true,
  revision: 1, structure_revision: 1, state_revision: 10, static_revision: 1,
  nodes: [node], edges: [], gateways: [], focus: node.address, ...overrides });
const delta = (overrides: Partial<NetMapDelta> = {}): NetMapDelta => ({ epoch: 'ui:one', full: false,
  base_revision: 10, state_revision: 11, ...overrides });

test('one changed endpoint preserves all other entries and unchanged edge arrays', () => {
  const stream = new NetrunMapStream();
  const nodes = Array.from({ length: 6000 }, (_, index) => ({ ...node, address: `N${index}` }));
  const first = stream.apply(baseline({ nodes }));
  const changed = stream.apply(delta({ nodes: [{ ...nodes[100], entities: 2 }] }));
  expect(changed.nodes).toHaveLength(6000);
  expect(changed.nodes[100].entities).toBe(2);
  expect(changed.nodes[0]).toBe(first.nodes[0]);
  expect(changed.nodes[5999]).toBe(first.nodes[5999]);
  expect(changed.edges).toBe(first.edges);
  expect(first.nodes[100].entities).toBe(0);
});

test('idle packets do not enumerate, copy or serialize the retained 6000-node baseline', () => {
  const stream = new NetrunMapStream();
  let reads = 0;
  const nodes = new Proxy(Array.from({ length: 6000 }, (_, index) => ({ ...node, address: `N${index}` })), {
    get: (target, key, receiver) => { reads++; return Reflect.get(target, key, receiver); },
  });
  const first = stream.apply(baseline({ nodes }));
  const initialReads = reads;
  for (let i = 0; i < 20; i++) {
    expect(stream.apply(delta({ state_revision: 10, nodes: [], edges: [], gateways: [] }))).toBe(first);
  }
  expect(reads).toBe(initialReads);
});

test('metadata updates at the same graph revision retain graph arrays', () => {
  const stream = new NetrunMapStream();
  const first = stream.apply(baseline());
  const route = { route: ['APC'], hops: 0, latency: 0, revision: 12, reachable: true };
  const next = stream.apply(delta({ state_revision: 10, focus: 'OTHER', route }));
  expect(next.focus).toBe('OTHER');
  expect(next.route).toEqual(route);
  expect(next.nodes).toBe(first.nodes);
  expect(next.edges).toBe(first.edges);
  expect(stream.apply(delta({ state_revision: 10, focus: 'OTHER', route: { ...route, route: ['APC'] } }))).toBe(next);
});

test('deletion removes the endpoint and any remaining incident links', () => {
  const stream = new NetrunMapStream();
  stream.apply(baseline({ nodes: [node, { ...node, address: 'PEER' }],
    edges: [{ id: 'link', from: 'APC', to: 'PEER', kind: 'endpoint' }] }));
  const deleted = stream.apply(delta({ removed_nodes: ['PEER'] }));
  expect(deleted.nodes.map((entry) => entry.address)).toEqual(['APC']);
  expect(deleted.edges).toEqual([]);
});

test('a missing baseline or a lost delta requests one resync and suppresses stale authorized data', () => {
  const stream = new NetrunMapStream();
  expect(stream.apply(delta())).toBeNull();
  expect(stream.resyncToken).toBe(1);
  expect(stream.apply(delta({ state_revision: 12 }))).toBeNull();
  expect(stream.resyncToken).toBe(1);
  stream.apply(baseline());
  expect(stream.apply(delta({ base_revision: 11, state_revision: 12 }))).toBeNull();
  expect(stream.resyncToken).toBe(2);
  const restored = stream.apply(baseline({ nodes: [{ ...node, address: 'ONLY-PERMITTED' }], state_revision: 12 }));
  expect(restored.nodes.map((entry) => entry.address)).toEqual(['ONLY-PERMITTED']);
});

test('same-epoch lost delta retains the old map until a confirmed full snapshot', () => {
  const stream = new NetrunMapStream();
  const initial = stream.apply(baseline());
  const retained = stream.apply(delta({ base_revision: 9, state_revision: 12 }));
  expect(retained).toBe(initial);
  expect(stream.needsResync).toBe(true);
  expect(stream.resyncToken).toBe(1);
  expect(stream.apply(delta({ base_revision: 10, state_revision: 13, nodes: [{ ...node, name: 'Unconfirmed' }] }))).toBe(initial);
  expect(initial.nodes[0].name).toBe('APC');
  const restored = stream.apply(baseline({ state_revision: 13, nodes: [{ ...node, name: 'Confirmed' }] }));
  expect(restored.nodes[0].name).toBe('Confirmed');
  expect(stream.needsResync).toBe(false);
});

test('new authorization epoch drops all previously disclosed nodes immediately', () => {
  const stream = new NetrunMapStream();
  stream.apply(baseline());
  expect(stream.apply(delta({ epoch: 'ui:revoked', base_revision: 10, state_revision: 12 }))).toBeNull();
  expect(stream.needsResync).toBe(true);
  expect(stream.apply(baseline({ epoch: 'ui:revoked', nodes: [] })).nodes).toEqual([]);
});

test('authorization epochs replace the baseline and independent windows keep separate cursors', () => {
  const first = new NetrunMapStream(), second = new NetrunMapStream();
  first.apply(baseline({ apc_zones: [{ address: 'APC', z: 1, runs: [{ x: 1, y: 1, width: 3 }] }] }));
  second.apply(baseline({ epoch: 'ui:two' }));
  const changed = first.apply(baseline({ epoch: 'ui:one:authorized', state_revision: 1, nodes: [], apc_zones: [] }));
  expect(changed.nodes).toEqual([]);
  expect(changed.apc_zones).toEqual([]);
  expect(second.apply(delta({ epoch: 'ui:two', nodes: [{ ...node, entities: 1 }] })).nodes[0].entities).toBe(1);
  expect(first.apply(delta({ epoch: 'ui:one', state_revision: 20 }))).toBeNull();
  expect(second.resyncToken).toBe(0);
});

test('out-of-order graph packets do not resurrect deleted endpoints or older metadata', () => {
  const stream = new NetrunMapStream();
  stream.apply(baseline());
  const removed = stream.apply(delta({ removed_nodes: ['APC'], focus: null }));
  expect(stream.apply(delta({ state_revision: 10, nodes: [node], focus: 'APC' }))).toBe(removed);
});

test('BYOND numeric boolean flags select the same baseline and delta protocol', () => {
  const stream = new NetrunMapStream();
  stream.apply(baseline({ full: 1 }));
  const next = stream.apply(delta({ full: 0, nodes: [{ ...node, entities: 2 }] }));
  expect(next.nodes).toHaveLength(1);
  expect(next.nodes[0].entities).toBe(2);
  expect(stream.resyncToken).toBe(0);
});
