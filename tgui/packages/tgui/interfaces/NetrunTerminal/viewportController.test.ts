import { GraphScene, PlacedNode } from './graphScene';
import { makePixiSurfaceMock } from './testSupport/pixiSurfaceMock';
import { NetworkViewportController, ViewportSnapshot } from './viewportController';

const node: PlacedNode = { address: 'APC', name: 'APC', type: 'apc', x: 0, y: 0, px: 0, py: 0,
  security: 1, online: true, access: 2, active: false, entities: 0, uplink: null };
const snapshot = (): ViewportSnapshot => {
  const base = new GraphScene(); base.update([node], []);
  return { base, scene: base, overlay: { gateways: new Map(), selected: 'APC', jacked: null,
    entityHost: null, selectedRoute: [], waypointRoute: [], pingRoute: [], events: [] },
  adjacency: base.adjacency, dynamicEdges: [], suspended: false };
};
const callbacks = () => ({ onStatus: jest.fn(), onHUD: jest.fn(), onHover: jest.fn(), onSelect: jest.fn() });
const hostElement = () => {
  const host = document.createElement('div');
  host.tabIndex = 0;
  Object.defineProperties(host, { clientWidth: { configurable: true, value: 720 }, clientHeight: { configurable: true, value: 480 } });
  host.getBoundingClientRect = () => ({ left: 0, top: 0, width: 720, height: 480, right: 720, bottom: 480, x: 0, y: 0, toJSON: () => ({}) });
  document.body.appendChild(host);
  return host;
};
const pointer = (host: HTMLElement, type: string, x: number, y: number, pointerId = 1) => {
  const event = new MouseEvent(type, { clientX: x, clientY: y, button: 0, bubbles: true });
  Object.defineProperty(event, 'pointerId', { value: pointerId });
  host.dispatchEvent(event);
};

test('hiding a ready workspace preserves its context and camera but pauses all GPU work', async () => {
  const host = hostElement(), data = snapshot(), handlers = callbacks();
  const factory = jest.fn(async (element: HTMLElement) => makePixiSurfaceMock(element));
  const controller = new NetworkViewportController(data, handlers, factory);
  try {
    controller.attach(host);
    const surface = await factory.mock.results[0].value;
    await Promise.resolve();
    controller.center('APC');
    pointer(host, 'pointerdown', 360, 240); pointer(host, 'pointermove', 430, 260); pointer(host, 'pointerup', 430, 260);
    const camera = { x: controller.camera.x, y: controller.camera.y, zoom: controller.camera.zoom };
    const uploads = surface.updateActors.mock.calls.length;
    controller.update({ ...data, suspended: true });
    expect(surface.setSuspended).toHaveBeenLastCalledWith(true);
    expect(surface.destroy).not.toHaveBeenCalled();
    pointer(host, 'pointermove', 600, 300);
    controller.update({ ...data, suspended: true, overlay: { ...data.overlay, selected: null } });
    expect(surface.updateActors).toHaveBeenCalledTimes(uploads);
    controller.update(data);
    expect(factory).toHaveBeenCalledTimes(1);
    expect(surface.setSuspended).toHaveBeenLastCalledWith(false);
    expect({ x: controller.camera.x, y: controller.camera.y, zoom: controller.camera.zoom }).toEqual(camera);
  } finally { controller.detach(); host.remove(); }
});

test('an initialization finishing after hiding is cancelled and cannot attach a stale surface', async () => {
  const host = hostElement(), data = snapshot(), handlers = callbacks();
  let resolve;
  const factory = jest.fn((_element, _width, _height, _unavailable, _options) => new Promise<any>((finish) => { resolve = finish; }));
  const controller = new NetworkViewportController(data, handlers, factory);
  controller.attach(host);
  const signal = factory.mock.calls[0][4].signal;
  controller.update({ ...data, suspended: true });
  expect(signal.aborted).toBe(true);
  const stale = makePixiSurfaceMock(host);
  resolve(stale);
  await Promise.resolve();
  expect(stale.destroy).toHaveBeenCalledTimes(1);
  expect(host.querySelector('canvas')).toBeNull();
  expect(handlers.onStatus).toHaveBeenLastCalledWith({ phase: 'paused' });
  controller.detach(); host.remove();
});

test('pan and zoom update the GPU camera without reuploading the graph or reconciling the HUD on every pan pixel', async () => {
  const host = hostElement(), data = snapshot(), handlers = callbacks();
  const factory = jest.fn(async (element: HTMLElement) => makePixiSurfaceMock(element));
  const controller = new NetworkViewportController(data, handlers, factory);
  try {
    controller.attach(host);
    const surface = await factory.mock.results[0].value;
    await Promise.resolve();
    const uploads = surface.updateScene.mock.calls.length, actors = surface.updateActors.mock.calls.length;
    handlers.onHUD.mockClear();
    pointer(host, 'pointerdown', 360, 240);
    for (let step = 1; step <= 8; step++) { pointer(host, 'pointermove', 360 + step * 10, 240); }
    pointer(host, 'pointerup', 440, 240);
    expect(surface.updateScene).toHaveBeenCalledTimes(uploads);
    expect(surface.updateActors).toHaveBeenCalledTimes(actors);
    expect(handlers.onHUD).not.toHaveBeenCalled();
    pointer(host, 'pointerdown', 440, 240); pointer(host, 'pointerup', 440, 240);
    expect(handlers.onSelect).toHaveBeenCalledWith('APC');
    const actorsAfterSelection = surface.updateActors.mock.calls.length;
    const fitPoints = jest.spyOn(data.scene, 'fitPoints');
    for (let count = 0; count < 6; count++) {
      host.dispatchEvent(new WheelEvent('wheel', { clientX: 440, clientY: 240, deltaY: 15, cancelable: true }));
    }
    expect(fitPoints).toHaveBeenCalledTimes(1);
    expect(surface.updateScene).toHaveBeenCalledTimes(uploads);
    expect(surface.updateActors).toHaveBeenCalledTimes(actorsAfterSelection);
    expect(handlers.onHUD).toHaveBeenCalled();
  } finally { controller.detach(); host.remove(); }
});

test('a failed GPU start waits for an explicit retry and creates no 2D fallback', async () => {
  const host = hostElement(), data = snapshot(), handlers = callbacks();
  const factory = jest.fn(async (_element: HTMLElement): Promise<any> => null);
  const controller = new NetworkViewportController(data, handlers, factory);
  try {
    controller.attach(host); await Promise.resolve();
    expect(handlers.onStatus).toHaveBeenLastCalledWith(expect.objectContaining({ phase: 'error' }));
    controller.update({ ...data, overlay: { ...data.overlay, events: [] } });
    expect(factory).toHaveBeenCalledTimes(1);
    expect(host.querySelector('canvas, svg')).toBeNull();
    factory.mockImplementationOnce(async (element) => makePixiSurfaceMock(element));
    controller.retry(); await Promise.resolve();
    expect(handlers.onStatus).toHaveBeenLastCalledWith({ phase: 'ready' });
    expect(host.querySelectorAll('[data-net-pixi]')).toHaveLength(1);
  } finally { controller.detach(); host.remove(); }
});

test('empty filters pause the same surface and final detach removes listeners and resources', async () => {
  const host = hostElement(), data = snapshot(), handlers = callbacks();
  const factory = jest.fn(async (element: HTMLElement) => makePixiSurfaceMock(element));
  const controller = new NetworkViewportController(data, handlers, factory);
  controller.attach(host);
  const surface = await factory.mock.results[0].value;
  await Promise.resolve();
  const empty = new GraphScene(); empty.update([], []);
  controller.update({ ...data, base: empty, scene: empty });
  expect(handlers.onStatus).toHaveBeenLastCalledWith({ phase: 'empty' });
  expect(surface.setSuspended).toHaveBeenLastCalledWith(true);
  controller.update(data);
  expect(factory).toHaveBeenCalledTimes(1);
  controller.detach();
  expect(surface.destroy).toHaveBeenCalledTimes(1);
  expect(host.querySelector('canvas')).toBeNull();
  handlers.onSelect.mockClear();
  pointer(host, 'pointerdown', 360, 240); pointer(host, 'pointerup', 360, 240);
  expect(handlers.onSelect).not.toHaveBeenCalled();
  host.remove();
});

test('a local selection highlights immediately while machine permissions remain server-confirmed', async () => {
  const host = hostElement(), data = snapshot();
  const peer = { ...node, address: 'PEER', name: 'Сервер', px: 96 };
  data.base.update([node, peer], []);
  const handlers = { ...callbacks(), onSelectionFeedback: jest.fn() };
  const factory = jest.fn(async (element: HTMLElement) => makePixiSurfaceMock(element));
  const controller = new NetworkViewportController(data, handlers, factory);
  try {
    controller.attach(host); const surface = await factory.mock.results[0].value; await Promise.resolve();
    controller.previewSelection('PEER');
    expect(surface.updateActors).toHaveBeenLastCalledWith(data.scene,
      expect.objectContaining({ selected: 'PEER', selectionPending: true }), data.dynamicEdges, data.adjacency);
    expect(data.overlay.selected).toBe('APC');
    expect(handlers.onSelectionFeedback).toHaveBeenLastCalledWith(expect.objectContaining({ phase: 'pending', address: 'PEER' }));
    controller.update({ ...data, overlay: { ...data.overlay, selected: 'PEER' } });
    expect(surface.updateActors).toHaveBeenLastCalledWith(data.scene,
      expect.objectContaining({ selected: 'PEER', selectionPending: false }), data.dynamicEdges, data.adjacency);
    expect(handlers.onSelectionFeedback).toHaveBeenLastCalledWith(expect.objectContaining({ phase: 'confirmed', address: 'PEER' }));
  } finally { controller.detach(); host.remove(); }
});

test('a superseded selection cannot expire the new one and an unconfirmed choice returns to server state', async () => {
  jest.useFakeTimers();
  const host = hostElement(), data = snapshot();
  const handlers = { ...callbacks(), onSelectionFeedback: jest.fn() };
  const factory = jest.fn(async (element: HTMLElement) => makePixiSurfaceMock(element));
  const controller = new NetworkViewportController(data, handlers, factory);
  try {
    controller.attach(host); const surface = await factory.mock.results[0].value; await Promise.resolve();
    controller.previewSelection('FIRST'); jest.advanceTimersByTime(3500);
    controller.previewSelection('SECOND'); jest.advanceTimersByTime(1000);
    expect(handlers.onSelectionFeedback).toHaveBeenLastCalledWith(expect.objectContaining({ phase: 'pending', address: 'SECOND' }));
    jest.advanceTimersByTime(3000);
    expect(handlers.onSelectionFeedback).toHaveBeenLastCalledWith(expect.objectContaining({ phase: 'timeout', address: 'SECOND' }));
    expect(surface.updateActors).toHaveBeenLastCalledWith(data.scene,
      expect.objectContaining({ selected: 'APC', selectionPending: false }), data.dynamicEdges, data.adjacency);
    controller.previewSelection('THIRD'); controller.rejectSelection('Узел больше недоступен.');
    expect(handlers.onSelectionFeedback).toHaveBeenLastCalledWith(expect.objectContaining({ phase: 'rejected', message: 'Узел больше недоступен.' }));
    controller.detach();
    expect(jest.getTimerCount()).toBe(0);
  } finally { controller.detach(); host.remove(); jest.useRealTimers(); }
});

test('pointer hit testing follows the rendered mobile position and an engine miss stays a miss', async () => {
  const host = hostElement(), data = snapshot(), handlers = callbacks();
  const factory = jest.fn(async (element: HTMLElement) => makePixiSurfaceMock(element));
  const controller = new NetworkViewportController(data, handlers, factory);
  try {
    controller.attach(host); const surface = await factory.mock.results[0].value; await Promise.resolve();
    surface.hitTest = jest.fn(() => ({ ...node, address: 'INTERPOLATED-MOBILE', dynamic: true }));
    pointer(host, 'pointerdown', 360, 240); pointer(host, 'pointerup', 360, 240);
    expect(handlers.onSelect).toHaveBeenLastCalledWith('INTERPOLATED-MOBILE');
    surface.hitTest.mockReturnValueOnce(null);
    expect(controller.hit(360, 240)).toBeNull();
  } finally { controller.detach(); host.remove(); }
});

test('context recovery keeps the loading state through incoming data and resumes the same surface', async () => {
  const host = hostElement(), data = snapshot(), handlers = callbacks();
  const factory = jest.fn(async (element, _width, _height, _unavailable, _options) => makePixiSurfaceMock(element));
  const controller = new NetworkViewportController(data, handlers, factory);
  try {
    controller.attach(host); const surface = await factory.mock.results[0].value; await Promise.resolve();
    factory.mock.calls[0][4].onStatus('lost');
    controller.update({ ...data, overlay: { ...data.overlay, selected: null } });
    expect(handlers.onStatus).toHaveBeenLastCalledWith(expect.objectContaining({ phase: 'loading' }));
    pointer(host, 'pointerdown', 360, 240); pointer(host, 'pointerup', 360, 240);
    expect(handlers.onSelect).not.toHaveBeenCalled();
    factory.mock.calls[0][4].onStatus('ready');
    expect(handlers.onStatus).toHaveBeenLastCalledWith({ phase: 'ready' });
    expect(factory).toHaveBeenCalledTimes(1);
    expect(surface.destroy).not.toHaveBeenCalled();
  } finally { controller.detach(); host.remove(); }
});
