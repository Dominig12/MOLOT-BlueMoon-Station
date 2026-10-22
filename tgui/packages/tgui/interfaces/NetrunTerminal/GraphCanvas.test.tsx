import { act, fireEvent, render } from '@testing-library/react';

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

test('stationary rendering has bounded geometry and contains no route or event animation', () => {
  const calls = new Map<string, jest.Mock>();
  const context = new Proxy({}, { get: (_target, name: string) => {
    if (!calls.has(name)) { calls.set(name, name === 'measureText' ? jest.fn((text: string) => ({ width: text.length * 7 })) : jest.fn()); }
    return calls.get(name);
  } }) as CanvasRenderingContext2D;
  const scene = new GraphScene(); scene.update([node, { ...node, address: 'B', px: 96 }], []);
  const renderer = new GraphRenderer(), camera = new GraphViewport(); camera.fit(scene.nodes, 720, 480);
  expect(renderer.paint(context, scene, camera, overlay, 720, 480, 1)).toBeUndefined();
  expect(calls.get('lineTo').mock.calls).not.toContainEqual([96, 0]);
  for (const args of calls.get('rect').mock.calls) { expect(args[2]).toBeLessThanOrEqual(GRAPH_GLYPH_RADIUS * 2); }
});

test('APC shading follows each actual area run instead of inventing a rectangular powered zone', () => {
  const calls = new Map<string, jest.Mock>();
  const context = new Proxy({}, { get: (_target, name: string) => {
    if (!calls.has(name)) { calls.set(name, name === 'measureText' ? jest.fn((text: string) => ({ width: text.length * 7 })) : jest.fn()); }
    return calls.get(name);
  } }) as CanvasRenderingContext2D;
  const scene = new GraphScene(); scene.update([node], []);
  const renderer = new GraphRenderer(), camera = new GraphViewport(); camera.fit(scene.nodes, 720, 480);
  renderer.paint(context, scene, camera, { ...overlay, apcZones: [{ address: 'APC', z: 1,
    runs: [{ x: 20, y: 30, width: 4 }, { x: 20, y: 31, width: 1 }] }] }, 720, 480, 1);
  expect(calls.get('fillRect').mock.calls).toContainEqual([19.5 * 96, -30.5 * 96, 4 * 96, 96]);
  expect(calls.get('fillRect').mock.calls).toContainEqual([19.5 * 96, -31.5 * 96, 96, 96]);
  expect(calls.get('fillRect').mock.calls).not.toContainEqual([19.5 * 96, -31.5 * 96, 4 * 96, 2 * 96]);
});

test('overview keeps all 6000 geographic markers instead of collapsing them into LAN clusters', () => {
  const calls = new Map<string, jest.Mock>();
  const context = new Proxy({}, { get: (_target, name: string) => {
    if (!calls.has(name)) { calls.set(name, name === 'measureText' ? jest.fn((text: string) => ({ width: text.length * 7 })) : jest.fn()); }
    return calls.get(name);
  } }) as CanvasRenderingContext2D;
  const nodes = Array.from({ length: 6000 }, (_, i) => ({ ...node, address: `N${i}`, type: 'camera', network: i % 2 ? 'A' : 'B', px: (i % 80) * 96, py: Math.floor(i / 80) * 96 }));
  const scene = new GraphScene(); scene.update(nodes, []);
  const renderer = new GraphRenderer(), camera = new GraphViewport(); camera.fit(scene.nodes, 350, 250);
  renderer.paint(context, scene, camera, overlay, 350, 250, 1);
  expect(calls.get('arc')).toHaveBeenCalledTimes(6000);
});

test('live actors and overlays leave the retained base untouched; camera and stationary changes draw once', () => {
  const originalRequest = window.requestAnimationFrame, originalCancel = window.cancelAnimationFrame;
  const frames = new Map<number, FrameRequestCallback>(); let sequence = 0;
  window.requestAnimationFrame = jest.fn((callback) => { frames.set(++sequence, callback); return sequence; });
  window.cancelAnimationFrame = jest.fn((id) => { frames.delete(id); });
  const context = jest.spyOn(HTMLCanvasElement.prototype, 'getContext').mockReturnValue({} as CanvasRenderingContext2D);
  const painted = jest.spyOn(GraphRenderer.prototype, 'paint').mockImplementation(() => {});
  const flush = () => act(() => {
    const pending = [...frames]; frames.clear(); pending.forEach(([, callback]) => callback(0));
  });
  const mobile = { ...node, address: 'M', type: 'phone', dynamic: true, x: 1, px: 96 };
  const base = [node], staticEdges = [];
  const props = { ...overlay, nodes: base, edges: staticEdges, actors: [node, mobile], dynamicEdges: [],
    positions: new Map([['APC', node], ['M', mobile]]), adjacency: new Map(), focus: null, onSelect: jest.fn() };
  const rendered = render(<GraphCanvas {...props} />);
  flush(); expect(painted).toHaveBeenCalledTimes(1); expect(frames.size).toBe(0);
  const originalCamera = rendered.container.querySelector('[data-net-camera]').getAttribute('transform');
  rendered.rerender(<GraphCanvas {...props} selected="M" selectedRoute={['APC', 'M']}
    actors={[{ ...node, entities: 3, ice: 2, active: true }, { ...mobile, px: 144, x: 1.5 }]}
    events={[{ kind: 'trace', from: 'APC', to: 'M', age: 0 }]} />);
  expect(rendered.container.querySelector('[data-net-dynamic-node="M"]').getAttribute('transform')).toBe('translate(144 0)');
  expect(rendered.container.querySelector('[data-net-processes="3"]')).not.toBeNull();
  expect(rendered.container.querySelector('[data-net-event="trace"]')).not.toBeNull();
  expect(rendered.container.querySelector('[data-net-camera]').getAttribute('transform')).toBe(originalCamera);
  expect(painted).toHaveBeenCalledTimes(1); expect(frames.size).toBe(0);
  fireEvent.wheel(rendered.getByLabelText('Карта сети'), { clientX: 360, clientY: 240, deltaY: -40 });
  flush(); expect(painted).toHaveBeenCalledTimes(2); expect(frames.size).toBe(0);
  const updated = { ...props, nodes: [{ ...node, online: false }] };
  rendered.rerender(<GraphCanvas {...updated} />); expect(frames.size).toBe(1);
  // Suspending cancels pending work and removes CSS animations; resume draws the latest base.
  rendered.rerender(<GraphCanvas {...updated} suspended />);
  expect(frames.size).toBe(0); expect(rendered.container.querySelector('[data-net-actors]')).toBeNull();
  rendered.rerender(<GraphCanvas {...updated} />); flush();
  expect(painted).toHaveBeenCalledTimes(3); expect(frames.size).toBe(0);
  rendered.unmount(); painted.mockRestore(); context.mockRestore();
  window.requestAnimationFrame = originalRequest; window.cancelAnimationFrame = originalCancel;
});


test('large map painter yields between steps while retaining every marker', () => {
  let markers = 0;
  const context = new Proxy({}, { get: (_target, name: string) => {
    if (name === 'createRadialGradient') { return () => ({ addColorStop: () => {} }); }
    if (name === 'measureText') { return (value: string) => ({ width: value.length * 7 }); }
    return () => { if (name === 'arc') { markers++; } };
  } }) as CanvasRenderingContext2D;
  const scene = new GraphScene();
  scene.update(Array.from({ length: 600 }, (_, i) => ({
    ...node, address: 'N' + i, px: i * 4, py: 0, type: 'camera',
  })), []);
  const renderer = new GraphRenderer(), camera = new GraphViewport();
  camera.fit(scene.nodes, 720, 480);
  const job = renderer.paintChunks(context, scene, camera, overlay, 720, 480, 1, 32);
  expect(job.next().done).toBe(false);
  expect(markers).toBeLessThan(600);
  let iterations = 0;
  while (!job.next().done && iterations < 1500) { iterations++; }
  expect(iterations).toBeLessThan(1500);
  expect(markers).toBe(600);
});
