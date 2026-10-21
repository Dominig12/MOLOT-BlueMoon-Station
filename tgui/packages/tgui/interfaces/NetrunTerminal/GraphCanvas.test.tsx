import { fireEvent, render } from '@testing-library/react';

import { GraphCanvas } from './GraphCanvas';
import { GRAPH_GLYPH_RADIUS } from './graphLayout';
import { GraphRenderer } from './graphRenderer';
import { GraphScene, PlacedNode } from './graphScene';
import { GraphViewport } from './graphViewport';

const node: PlacedNode = { address: 'APC', name: 'Первое имя', type: 'apc', x: 0, y: 0, px: 0, py: 0,
  security: 1, online: true, access: 1, active: false, entities: 0, uplink: null };
const overlay = { gateways: new Map(), selected: 'APC', jacked: null, entityHost: null,
  selectedRoute: [], waypointRoute: [], pingRoute: [], events: [] };

test('a stationary tooltip reads live node data and disappears on removal or pointer leave', () => {
  const originalPointer = window.PointerEvent;
  Object.defineProperty(window, 'PointerEvent', { value: MouseEvent, configurable: true });
  const props = { ...overlay, nodes: [node], edges: [], positions: new Map([['APC', node]]),
    adjacency: new Map(), focus: 'APC', onSelect: jest.fn() };
  const { getByLabelText, getByRole, queryByRole, rerender } = render(<GraphCanvas {...props} />);
  fireEvent.pointerMove(getByLabelText('Карта сети'), { clientX: 360, clientY: 240 });
  expect(getByRole('tooltip').textContent).toContain('Первое имя');
  rerender(<GraphCanvas {...props} nodes={[{ ...node, name: 'Новое имя', online: false }]} />);
  expect(getByRole('tooltip').textContent).toContain('Новое имя');
  expect(getByRole('tooltip').textContent).toContain('Не отвечает');
  fireEvent.pointerLeave(getByLabelText('Карта сети'));
  expect(queryByRole('tooltip')).toBeNull();
  fireEvent.pointerMove(getByLabelText('Карта сети'), { clientX: 360, clientY: 240 });
  rerender(<GraphCanvas {...props} nodes={[]} />);
  expect(queryByRole('tooltip')).toBeNull();
  Object.defineProperty(window, 'PointerEvent', { value: originalPointer, configurable: true });
});

test('event animation ends, marker geometry remains bounded and missing route segments do not draw', () => {
  const calls = new Map<string, jest.Mock>();
  const context = new Proxy({}, { get: (_target, name: string) => {
    if (!calls.has(name)) { calls.set(name, name === 'measureText' ? jest.fn((text: string) => ({ width: text.length * 7 })) : jest.fn()); }
    return calls.get(name);
  } }) as CanvasRenderingContext2D;
  const scene = new GraphScene(); scene.update([node, { ...node, address: 'B', px: 96 }], []);
  const renderer = new GraphRenderer(), camera = new GraphViewport(); camera.fit(scene.nodes, 720, 480);
  const events = [{ kind: 'trace' as const, from: 'APC', to: 'B', age: 0 }];
  renderer.update(scene, events, 0);
  expect(renderer.paint(context, scene, camera, { ...overlay, events, selectedRoute: ['APC', 'MISSING', 'B'] }, 720, 480, 1, 0)).toBe(true);
  // No real edge exists, therefore neither route nor a shortcut may emit lineTo.
  // The background grid and APC inner cross also draw lines, so inspect world segment endpoints.
  expect(calls.get('lineTo').mock.calls).not.toContainEqual([96, 0]);
  for (const args of calls.get('arc').mock.calls) { expect(args[2]).toBeLessThanOrEqual(GRAPH_GLYPH_RADIUS); }
  expect(renderer.paint(context, scene, camera, { ...overlay, events }, 720, 480, 1, 5000)).toBe(false);
});
