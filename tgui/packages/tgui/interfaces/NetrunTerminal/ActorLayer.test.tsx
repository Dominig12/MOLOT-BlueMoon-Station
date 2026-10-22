import { render } from '@testing-library/react';

import { ActorLayer } from './ActorLayer';
import { PlacedNode } from './graphScene';

const actor = (address: string, px: number, py: number, extra: Partial<PlacedNode>): PlacedNode => ({
  address, name: `Узел ${address}`, type: 'camera', x: 0, y: 0, px, py,
  security: 1, online: true, access: 1, active: false, entities: 0, uplink: null, ...extra,
});

test('draws reactive DOM markers for moving ICE and processes, projected by the shared viewport', () => {
  const actors = [actor('ICE', 0, 0, { ice: 2 }), actor('PROC', 100, 0, { entities: 3 })];
  const points = new Map([['SRV', { px: 50, py: 0 }]]);
  const { container, getByText } = render(
    <ActorLayer actors={actors} events={[{ kind: 'trace', from: 'SRV', to: 'SRV', age: 0 }]}
      points={points} vx={10} vy={20} vzoom={2} width={800} height={600} />);
  expect(getByText('2')).toBeTruthy();
  expect(getByText('3')).toBeTruthy();
  expect(container.querySelector('.netrun-ice-ring')).not.toBeNull();
  // The trace event renders a ripple anchored at the projected node position.
  expect(container.querySelector('.netrun-ripple')).not.toBeNull();
});

test('culls actors and expired events that fall outside the viewport', () => {
  const actors = [actor('FAR', 100000, 100000, { ice: 1 })];
  const points = new Map([['SRV', { px: 0, py: 0 }]]);
  const { container } = render(
    <ActorLayer actors={actors} events={[{ kind: 'trace', from: 'SRV', to: 'SRV', age: 9 }]}
      points={points} vx={0} vy={0} vzoom={1} width={400} height={300} />);
  expect(container.querySelector('.netrun-ice-ring')).toBeNull();
  expect(container.querySelector('.netrun-ripple')).toBeNull();
});
