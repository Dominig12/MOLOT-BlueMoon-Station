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


// Changing an edge's endpoints updates its incident index; later unrelated deletions
// must not remove the redirected link.
test('reconnecting an existing link preserves it when its old endpoint disappears', () => {
  const stream = new NetrunMapStream();
  const a = { ...node, address: 'A' }, b = { ...node, address: 'B' };
  const c = { ...node, address: 'C' };
  stream.apply(baseline({ nodes: [a, b, c],
    edges: [{ id: 'link', from: 'A', to: 'B', kind: 'endpoint' }] }));
  stream.apply(delta({ edges: [{ id: 'link', from: 'A', to: 'C', kind: 'endpoint' }] }));
  const oldRemoved = stream.apply(delta({ base_revision: 11, state_revision: 12, removed_nodes: ['B'] }));
  expect(oldRemoved.edges).toEqual([{ id: 'link', from: 'A', to: 'C', kind: 'endpoint' }]);
  const next = stream.apply(delta({ base_revision: 12, state_revision: 13, removed_nodes: ['C'] }));
  expect(next.edges).toEqual([]);
});

test('single node deletion does not make an extra full pass through the edge array', () => {
  const stream = new NetrunMapStream();
  const nodes = Array.from({ length: 3001 }, (_, id) => ({ ...node, address: `N${id}` }));
  const original = Array.from({ length: 3000 }, (_, i) =>
    ({ id: `E${i}`, from: 'N0', to: `N${i + 1}`, kind: 'endpoint' as const }));
  let reads = 0;
  const edges = new Proxy(original, {
    get(target, prop, receiver) { if (typeof prop === 'string' && Number.isInteger(Number(prop))) { reads++; }
      return Reflect.get(target, prop, receiver); },
  });
  stream.apply(baseline({ nodes, edges }));
  reads = 0;
  const updated = stream.apply(delta({ removed_nodes: ['N1'] }));
  expect(updated.edges).toHaveLength(2999);
  expect(reads).toBeGreaterThanOrEqual(3000);
  expect(reads).toBeLessThan(4500);
});

test('an edge may refer to a node reintroduced in the same update', () => {
  const stream = new NetrunMapStream();
  stream.apply(baseline());
  const result = stream.apply(delta({
    nodes: [{ ...node, address: 'NEW' }], removed_nodes: ['NEW'],
    edges: [{ id: 'added', from: 'APC', to: 'NEW', kind: 'endpoint' }],
  }));
  expect(result.nodes.map((entry) => entry.address)).toEqual(['APC', 'NEW']);
  expect(result.edges).toHaveLength(1);
  expect(stream.resyncToken).toBe(0);
});

test('invalid link upserts request resync without accepting unauthorized endpoints', () => {
  const stream = new NetrunMapStream();
  stream.apply(baseline());
  const result = stream.apply(delta({ removed_nodes: ['APC'],
    edges: [{ id: 'invalid', from: 'APC', to: 'HIDDEN', kind: 'endpoint' }] }));
  expect(result).toBeNull();
  expect(stream.resyncToken).toBe(1);
  expect(stream.apply(delta({ state_revision: 12 }))).toBeNull();
  expect(stream.resyncToken).toBe(1);
  expect(stream.apply(baseline({ epoch: 'ui:authorized', nodes: [], edges: [] })).nodes).toEqual([]);
});
