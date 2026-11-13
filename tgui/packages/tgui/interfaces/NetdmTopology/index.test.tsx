import { act as flush, fireEvent, render, screen } from '@testing-library/react';
import { combineReducers, createStore, setGlobalStore } from 'common/redux';

import { backendReducer, backendUpdate } from '../../backend';
import { debugReducer } from '../../debug';
import { NetdmTopology } from '.';
import { createScene, TopologyScene } from './scene';

// jsdom has no GPU: the renderer is replaced, the screen logic around it is real.
jest.mock('./scene', () => {
  class SceneCancelled extends Error {}
  return { createScene: jest.fn(), SceneCancelled };
});

const mockedCreate = createScene as jest.MockedFunction<typeof createScene>;

const fakeScene = (): jest.Mocked<TopologyScene> => ({
  backend: 'webgl',
  update: jest.fn(),
  setSelection: jest.fn(),
  setFilters: jest.fn(),
  fit: jest.fn(),
  destroy: jest.fn(),
});

const baseData = {
  z: 2,
  levels: [{ z: 1, name: 'CentCom' }, { z: 2, name: 'Station' }],
  observing: true,
  published: true,
  state: '',
  version: '7',
  age: 0.5,
  error: null,
  truncated: false,
  nodes: [['1', 10, 10, 21], ['50', 11, 10, 8]],
  edges: [['1', '50']],
  radio: [],
};

/** Renderer reports the screen sent to the server, oldest first. */
const rendererReports = () => (global as any).Byond.topic.mock.calls.map(([message]) => message)
  .filter(message => message.type === 'act/renderer')
  .map(message => JSON.parse(message.payload));

const setup = (initial: Record<string, unknown> = {}) => {
  (global as any).Byond = { winset: () => {}, winget: () => Promise.resolve(null), topic: jest.fn() };
  const store = createStore(combineReducers({ backend: backendReducer, debug: debugReducer }));
  setGlobalStore(store);
  store.dispatch(backendUpdate({ config: { interface: 'NetdmTopology' }, data: { ...baseData, ...initial } }));
  const ui = render(<NetdmTopology />);
  const push = (changes: Record<string, unknown>) => {
    store.dispatch(backendUpdate({ data: { ...baseData, ...changes } }));
    ui.rerender(<NetdmTopology />);
  };
  return { ...ui, push };
};

test('один renderer на всё время окна: обновления данных идут в существующую сцену', async () => {
  const scene = fakeScene();
  mockedCreate.mockResolvedValue(scene);
  const ui = setup();
  await flush(async () => {});
  expect(mockedCreate).toHaveBeenCalledTimes(1);
  expect(scene.update).toHaveBeenCalledTimes(1);
  const [first, level] = scene.update.mock.calls[0];
  expect(first.nodes.size).toBe(2);
  expect(level).toBe('2');
  expect(rendererReports().map(report => report.event)).toEqual(['init', 'drawn']);
  expect(rendererReports()[0]).toMatchObject({ backend: 'webgl', nodes: 2 });
  expect(rendererReports()[1]).toMatchObject({ backend: 'webgl', nodes: 2, links: 1, level: '2' });

  ui.push({ version: '8', nodes: [['1', 10, 10, 21], ['50', 12, 10, 10]], radio: [['50', '1']], edges: [] });
  expect(mockedCreate).toHaveBeenCalledTimes(1);
  const latest = scene.update.mock.calls.at(-1)![0];
  expect(latest.nodes.get('50')?.x).toBe(12);
  expect([...latest.links.values()].map(link => link.radio)).toEqual([true]);
  // The drawn report is sent once per renderer, not per update.
  expect(rendererReports()).toHaveLength(2);
  ui.unmount();
  expect(scene.destroy).toHaveBeenCalledTimes(1);
});

test('отчёт drawn уходит, когда в сцену впервые приходит непустой уровень', async () => {
  const scene = fakeScene();
  mockedCreate.mockResolvedValue(scene);
  const ui = setup({ version: null, nodes: [], edges: [] });
  await flush(async () => {});
  expect(rendererReports()).toMatchObject([{ event: 'init', nodes: 0 }]);

  ui.push({ version: '9' });
  expect(rendererReports()).toHaveLength(2);
  expect(rendererReports()[1]).toMatchObject({ event: 'drawn', nodes: 2, links: 1, level: '2' });
  expect(rendererReports()[1].updateMs).toEqual(expect.any(Number));
});

test('булевы поля DM приходят как 0 и 1 и не выводятся числом', async () => {
  mockedCreate.mockResolvedValue(fakeScene());
  const ui = setup({ observing: 1, published: 1, truncated: 0 });
  await flush(async () => {});
  expect(screen.queryByText('0')).toBeNull();
  expect(screen.queryByText(/ограниченная часть/)).toBeNull();

  ui.push({ observing: 1, published: 0, truncated: 1 });
  expect(screen.getByText(/ещё не опубликована/)).toBeTruthy();
  expect(screen.getByText(/ограниченная часть/)).toBeTruthy();

  ui.push({ observing: 0, published: 0, truncated: 0 });
  expect(screen.getByText(/Observe выключен/)).toBeTruthy();
  expect(screen.queryByText('0')).toBeNull();
});

test('выбор узла на карте открывает инспектор с его связями', async () => {
  const scene = fakeScene();
  mockedCreate.mockResolvedValue(scene);
  setup();
  await flush(async () => {});
  const callbacks = mockedCreate.mock.calls[0][1];
  flush(() => callbacks.onSelect('50'));
  expect(screen.getByText('Узел 50')).toBeTruthy();
  expect(screen.getByText('1')).toBeTruthy();
  expect(scene.setSelection).toHaveBeenLastCalledWith('50');
});

test('инспектор показывает узел без питания и его провода без связи', async () => {
  mockedCreate.mockResolvedValue(fakeScene());
  setup({ nodes: [['1', 10, 10, 16 + 32], ['50', 11, 10, 8 + 64]], edges: [], down: [['50', '1']] });
  await flush(async () => {});
  const callbacks = mockedCreate.mock.calls[0][1];
  flush(() => callbacks.onSelect('1'));
  expect(screen.getByText('APC, без питания')).toBeTruthy();
  expect(screen.getByText(/Провод без связи/)).toBeTruthy();
  flush(() => callbacks.onSelect('50'));
  expect(screen.getByText('устройство, провод, неисправен')).toBeTruthy();
});

test('без графики окно остаётся рабочим списком и умеет повторить попытку', async () => {
  mockedCreate.mockRejectedValueOnce(new Error('no_webgl'));
  setup();
  await flush(async () => {});
  expect(screen.getByText(/no_webgl/)).toBeTruthy();
  expect(screen.getByText('Список узлов')).toBeTruthy();
  const failure = (global as any).Byond.topic.mock.calls.map(([message]) => message)
    .find(message => message.type === 'act/renderer');
  expect(JSON.parse(failure.payload)).toMatchObject({ failure: 'no_webgl' });
  const scene = fakeScene();
  mockedCreate.mockResolvedValue(scene);
  fireEvent.click(screen.getByText('Повторить отрисовку'));
  await flush(async () => {});
  expect(mockedCreate).toHaveBeenCalledTimes(2);
  expect(scene.update).toHaveBeenCalled();
});

test('окно, закрытое до конца инициализации, освобождает созданную сцену', async () => {
  const scene = fakeScene();
  let resolve: (value: TopologyScene) => void = () => {};
  mockedCreate.mockReturnValue(new Promise(done => { resolve = done; }));
  const ui = setup();
  const isCancelled = mockedCreate.mock.calls[0][2];
  ui.unmount();
  expect(isCancelled()).toBe(true);
  await flush(async () => resolve(scene));
  expect(scene.destroy).toHaveBeenCalledTimes(1);
  expect(scene.update).not.toHaveBeenCalled();
});
