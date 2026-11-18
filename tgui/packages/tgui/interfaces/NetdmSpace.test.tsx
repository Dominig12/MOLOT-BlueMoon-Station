import { fireEvent, render, screen } from '@testing-library/react';
import { combineReducers, createStore, setGlobalStore } from 'common/redux';

import { backendReducer, backendUpdate } from '../backend';
import { debugReducer } from '../debug';
import { NetdmSpace } from './NetdmSpace';

// Keep the real screen logic, but avoid constructing a GPU renderer in jsdom.
jest.mock('./NetdmTopology', () => ({
  TopologyCanvas: ({ onSelect, focusRequest, focusTarget }: {
    onSelect: (id: string) => void;
    focusRequest: number;
    focusTarget: string | null;
  }) => (
    <>
      <button type="button" onClick={() => onSelect('2')}>Выбрать удалённый узел</button>
      <span data-testid="camera-target">{focusRequest ? focusTarget : 'none'}</span>
    </>
  ),
}));

const base = {
  title: 'Сетевое присутствие',
  z: 1,
  levels: [1],
  nodes: [['1', 10, 10, 16], ['2', 11, 10, 8]],
  edges: [['1', '2']],
  down: [],
  services: [
    { node: '1', type: 'network.shell', instance: 'shell.home', stale: false },
    { node: '2', type: 'network.shell', instance: 'shell.remote', stale: false },
  ],
  hostNode: '1',
  presence: {
    presence: 10, host: 'shell.home', generation: 1, state: 'active', status: 'active',
  },
  otherPresences: {},
  log: [],
  actionEntries: [],
  revision: 1,
  alarmPending: false,
  alarmWatch: null,
  machineCommand: null,
  routePreview: null,
  immersed: false,
  immersionEnabled: false,
  immersionReason: '',
  persona: null,
  life: { bots: [], activity: [], operators: [] },
  hack: null,
  chat: null,
};

const setup = (initial: Record<string, unknown> = {}) => {
  const topic = jest.fn();
  (global as any).Byond = { winset: () => {}, winget: () => Promise.resolve(null), topic };
  const store = createStore(combineReducers({ backend: backendReducer, debug: debugReducer }));
  setGlobalStore(store);
  const push = (changes: Record<string, unknown>) => store.dispatch(backendUpdate({
    config: { interface: 'NetdmSpace' },
    data: { ...base, ...initial, ...changes },
  }));
  push(initial);
  const ui = render(<NetdmSpace />);
  return {
    push: (changes: Record<string, unknown>) => {
      push(changes);
      ui.rerender(<NetdmSpace />);
    },
    // HackPanel refreshes keys on mount; it is not caused by map or service selection.
    actions: () => topic.mock.calls.map(([message]) => ({
      type: message.type, payload: message.payload ? JSON.parse(message.payload) : {},
    })).filter(item => item.type !== 'act/hack_keys'),
    ...ui,
  };
};

test('selected map node offers an explicit Host route preview; Enter never skips preview', () => {
  const { push, actions } = setup();
  fireEvent.click(screen.getByText('Выбрать удалённый узел'));
  expect(screen.getByText(/Проверить переход/)).toBeTruthy();
  fireEvent.keyDown(document.body, { key: 'Enter' });
  expect(actions().filter(item => item.type === 'act/move')).toEqual([]);
  fireEvent.keyDown(document.body, { key: 'g' });
  expect(actions().filter(item => item.type === 'act/preview_move')).toEqual([{
    type: 'act/preview_move', payload: { to: 'shell.remote' },
  }]);
  expect(actions().filter(item => item.type === 'act/move')).toEqual([]);
  push({
    routePreview: {
      target: 'shell.remote', status: 'ready', seconds: 2, hops: 1,
      radioHops: 0, nodes: ['1', '2'], radioLegs: [], limited: false,
    },
  });
  fireEvent.keyDown(document.body, { key: 'Enter' });
  expect(actions().filter(item => item.type === 'act/move')).toEqual([{
    type: 'act/move', payload: { to: 'shell.remote' },
  }]);
});

test('wrong target, inactive presence and chat do not enable movement hotkeys', () => {
  const { push, actions } = setup();
  fireEvent.click(screen.getByText('Выбрать удалённый узел'));
  push({
    routePreview: {
      target: 'shell.another', status: 'ready', seconds: 2, hops: 1,
      radioHops: 0, nodes: ['1', '2'], radioLegs: [],
    },
  });
  fireEvent.keyDown(document.body, { key: 'Enter' });
  expect(actions().filter(item => item.type === 'act/move')).toEqual([]);
  push({
    presence: { presence: 10, host: 'shell.home', generation: 1, state: 'suspended' },
    routePreview: null,
  });
  fireEvent.keyDown(document.body, { key: 'g' });
  expect(actions().filter(item => item.type === 'act/preview_move')).toEqual([]);
});

test('keyboard inspects known neighbors without sending travel or route requests', () => {
  const { actions } = setup({
    nodes: [['1', 10, 10, 16], ['2', 11, 10, 8], ['3', 10, 11, 40]],
    edges: [['1', '2']],
    down: [['1', '3']],
  });
  fireEvent.keyDown(document.body, { key: 'ArrowRight' });
  expect(screen.getByTestId('camera-target').textContent).toBe('2');
  fireEvent.keyDown(document.body, { key: 'ArrowRight' });
  expect(screen.getByTestId('camera-target').textContent).toBe('3');
  expect(actions()).toEqual([]);
  fireEvent.keyDown(document.body, { key: 'f' });
  expect(screen.getByTestId('camera-target').textContent).toBe('1');
  expect(actions()).toEqual([]);
});

test('an inactive operator may inspect an offline neighbor without a shell command', () => {
  const { actions } = setup({
    nodes: [['1', 10, 10, 16], ['2', 11, 10, 40]],
    edges: [],
    down: [['1', '2']],
    presence: { presence: 10, host: 'shell.home', generation: 1, state: 'suspended' },
  });
  fireEvent.click(screen.getByText(/Осмотреть узел 2/));
  expect(screen.getByTestId('camera-target').textContent).toBe('2');
  expect(actions()).toEqual([]);
});

test('switching service is local and opening its schema is an explicit Host request', () => {
  const { actions } = setup({
    services: [
      { node: '1', type: 'network.shell', instance: 'shell.home', stale: false },
      { node: '1', type: 'machine.control', instance: 'machine.switch', stale: false },
    ],
  });
  fireEvent.click(screen.getByText('Оболочка узла'));
  fireEvent.click(screen.getByText('machine control'));
  expect(actions()).toEqual([]);
  fireEvent.click(screen.getByText('Доступные действия'));
  expect(actions()).toEqual([{ type: 'act/act', payload: { line: 'api machine.control' } }]);
});

test('Host schema drives ordinary read-only action through the same shell transport', () => {
  const { push, actions } = setup({
    services: [
      { node: '1', type: 'machine.control', instance: 'machine.switch', stale: false },
    ],
  });
  const fields = (record: Record<string, string>) =>
    Object.entries(record).map(([name, value]) => ({ name, value }));
  fireEvent.click(screen.getByText('Доступные действия'));
  const catalogue = {
    id: 1, line: 'api machine.control', pending: false, status: 'ok', error: null,
    records: [fields({ type: 'machine.control', command: 'status', request: 'machine.status' })],
  };
  push({ actionEntries: [catalogue] });
  fireEvent.click(screen.getByText('Получить состояние'));
  expect(actions().filter(item => item.type === 'act/act').map(item => item.payload.line))
    .toEqual(['api machine.control', 'api machine.control status']);
  push({ actionEntries: [catalogue, {
    id: 2, line: 'api machine.control status', pending: false, status: 'ok', error: null, records: [],
  }] });
  fireEvent.click(screen.getByText('Отправить запрос'));
  expect(actions().filter(item => item.type === 'act/act').map(item => item.payload.line))
    .toEqual(['api machine.control', 'api machine.control status', 'invoke machine.switch status']);
});

test('stale service remains inspectable but sends no typed commands', () => {
  const { actions } = setup({
    services: [{ node: '1', type: 'machine.control', instance: 'machine.switch', stale: true }],
  });
  fireEvent.click(screen.getByText('Доступные действия'));
  expect(actions()).toEqual([]);
});

test('context shows recent activity for its node only without network requests', () => {
  const { actions } = setup({
    life: { bots: [], operators: [], activity: [
      { seq: 1, node: '1', kind: 'presence', name: 'Station bot', text: 'Прибыл' },
      { seq: 2, node: '2', kind: 'presence', name: 'Other bot', text: 'Ушел' },
    ] },
  });
  expect(screen.getByText(/Station bot: Прибыл/)).toBeTruthy();
  expect(screen.queryByText(/Other bot: Ушел/)).toBeNull();
  fireEvent.click(screen.getByText('Выбрать удалённый узел'));
  expect(screen.getByText(/Other bot: Ушел/)).toBeTruthy();
  expect(screen.queryByText(/Station bot: Прибыл/)).toBeNull();
  expect(actions()).toEqual([]);
});
