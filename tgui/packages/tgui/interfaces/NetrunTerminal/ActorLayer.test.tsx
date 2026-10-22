import { render } from '@testing-library/react';

import { ActorLayer } from './ActorLayer';
import { GraphScene, PlacedNode } from './graphScene';
import { NetEdge } from './types';

const node: PlacedNode = { address: 'APC', name: 'APC', type: 'apc', x: 0, y: 0, px: 0, py: 0,
  security: 1, online: true, access: 1, active: false, entities: 0, uplink: null };
const overlay = { gateways: new Map(), selected: null, jacked: null, entityHost: null,
  selectedRoute: [], waypointRoute: [], pingRoute: [], events: [] };
const camera = { x: 100, y: 100, zoom: 1, width: 720, height: 480 };

test('moving bodies, physical links and real routes update together without inventing shortcuts', () => {
  const mobile = { ...node, address: 'M', dynamic: true, px: 144, anchorX: 96, anchorY: 0, type: 'phone' };
  const edge: NetEdge = { id: 'mobile', from: 'APC', to: 'M', kind: 'endpoint' };
  const base = new GraphScene(); base.update([node], []);
  const adjacency = new Map([['APC', new Set(['M'])], ['M', new Set(['APC'])]]);
  const scene = GraphScene.live(base, [node, mobile], adjacency);
  const { container, rerender } = render(<ActorLayer {...overlay} camera={camera} scene={scene} adjacency={adjacency}
    dynamicEdges={[edge]} selected="M" selectedRoute={['APC', 'M', 'MISSING', 'APC']}
    events={[{ kind: 'trace', from: 'APC', to: 'M', age: 0 }, { kind: 'command', from: 'APC', to: 'M', age: 5 }]} />);
  expect(container.querySelector('[data-net-dynamic-node="M"]').getAttribute('transform')).toBe('translate(144 0)');
  expect(container.querySelector('[data-net-dynamic-edge="mobile"]').getAttribute('d')).toBe('M0,0L96,0');
  expect(container.querySelector('[data-net-route="selected"]').getAttribute('d')).toBe('M0,0L96,0');
  expect(container.querySelectorAll('[data-net-event]')).toHaveLength(1);
  const moved = { ...mobile, px: 192, anchorX: 192 };
  const next = GraphScene.live(base, [{ ...node, entities: 2, ice: 1 }, moved], adjacency);
  rerender(<ActorLayer {...overlay} camera={camera} scene={next} adjacency={adjacency} dynamicEdges={[edge]} />);
  expect(container.querySelector('[data-net-dynamic-node="M"]').getAttribute('transform')).toBe('translate(192 0)');
  expect(container.querySelector('[data-net-dynamic-edge="mobile"]').getAttribute('d')).toBe('M0,0L192,0');
  expect(container.querySelector('[data-net-processes="2"]')).not.toBeNull();
  expect(container.querySelector('[data-net-ice="1"]')).not.toBeNull();
  expect(next.hit({ px: 192, py: 0 }, 1).address).toBe('M');
  expect(next.hit({ px: 144, py: 0 }, 1)).toBeNull();
  expect(next.visible(-30, -30, 30, 30)[0].entities).toBe(2);
});

test('6000 quiet stationary devices create no actor elements and offscreen actors are culled', () => {
  const nodes = Array.from({ length: 6000 }, (_, i) => ({ ...node, address: `N${i}`, px: (i % 80) * 96, py: Math.floor(i / 80) * 96 }));
  const base = new GraphScene(); base.update(nodes, []);
  const distant = { ...node, address: 'OFFSCREEN', dynamic: true, px: 99999 };
  const scene = GraphScene.live(base, [...nodes, distant], new Map());
  const { container } = render(<ActorLayer {...overlay} camera={camera} scene={scene} adjacency={new Map()} dynamicEdges={[]} />);
  expect(container.querySelectorAll('[data-net-actor]')).toHaveLength(0);
  expect(container.querySelectorAll('[data-net-dynamic-body]')).toHaveLength(0);
});
