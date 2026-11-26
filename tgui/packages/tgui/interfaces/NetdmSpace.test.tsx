import { act, fireEvent, render, screen, within } from '@testing-library/react';
import { combineReducers, createStore, setGlobalStore } from 'common/redux';

import { backendReducer, backendUpdate } from '../backend';
import { debugReducer } from '../debug';
import { NetdmSpace } from './NetdmSpace';

// Keep the real screen logic, but avoid constructing a GPU renderer in jsdom.
jest.mock('./NetdmTopology', () => ({
  TopologyCanvas: ({ onSelect, focusRequest, focusTarget, signal }: {
    onSelect: (id: string) => void;
    focusRequest: number;
    focusTarget: string | null;
    signal?: { node: string; outcome: string };
  }) => (
    <>
      <button type="button" onClick={() => onSelect('2')}>Выбрать удалённый узел</button>
      <span data-testid="camera-target">{focusRequest ? focusTarget : 'none'}</span>
      <span data-testid="delivery-signal">{signal ? `${signal.node}:${signal.outcome}` : 'none'}</span>
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

const deviceTerminal = {
  title: 'АПЦ',
  entries: [],
  connectionReady: true,
  events: [],
  watches: ['oxygen'],
  limit: 1024,
  scriptLimit: 4096,
  disk: null,
  diskNotice: null,
  loadedScript: null,
  programsEnabled: true,
  kept: [],
};

const openPanel = (name: string) => fireEvent.click(
  within(screen.getByRole('tablist', { name: 'Панели сети' })).getByRole('tab', { name }),
);

test('an observer without a presence renders: the life payload is an empty list, not an object', () => {
  // DM sends `"life" = list()` when nobody is dived in, and BYOND serialises that as `[]`. A `??` default does
  // not fire for an array, so this payload used to crash the window with "not iterable" on the first render.
  const { actions } = setup({
    presence: null,
    life: [] as unknown as typeof base.life,
  });
  expect(screen.getByRole('tablist', { name: 'Панели сети' })).toBeTruthy();
  expect(actions()).toEqual([]);
});

test('partially filled life payload does not break the dock', () => {
  const { actions } = setup({
    life: { activity: [{ seq: 1, node: '1', kind: 'presence', name: 'Бот', text: 'Прибыл' }] } as unknown as typeof base.life,
  });
  expect(screen.getByText(/Бот: Прибыл/)).toBeTruthy();
  expect(actions()).toEqual([]);
});

test('terminal and editor keep their drafts while visiting the selected node and other panels', () => {
  const { actions } = setup({ terminal: deviceTerminal });
  fireEvent.click(screen.getByText('Выбрать удалённый узел'));
  openPanel('Терминал');
  const terminal = screen.getByRole('textbox', { name: 'Командная строка' });
  fireEvent.change(terminal, { target: { value: 'services' } });
  fireEvent.click(screen.getByText('Редактор'));
  const script = screen.getByPlaceholderText(/^observe atmos.sensor/) as HTMLTextAreaElement;
  fireEvent.change(script, { target: { value: '$state = self' } });
  openPanel('Карта');
  expect(screen.getByRole('heading', { name: 'Узел 2' })).toBeTruthy();
  openPanel('События');
  expect(screen.getByText('Доставленные события')).toBeTruthy();
  expect(screen.getByText('oxygen')).toBeTruthy();
  openPanel('Терминал');
  expect(screen.getByPlaceholderText(/^observe atmos.sensor/)).toBe(script);
  expect(script.value).toBe('$state = self');
  fireEvent.click(within(screen.getByRole('tabpanel')).getByRole('button', { name: 'Терминал' }));
  const restored = screen.getByRole('textbox', { name: 'Командная строка' }) as HTMLInputElement;
  expect(restored.value).toBe('services');
  expect(actions()).toEqual([]);
  fireEvent.keyDown(restored, { key: 'Enter' });
  expect(actions()).toEqual([{
    type: 'act/terminal', payload: { command: 'run', params: { line: 'services' } },
  }]);
});

test('node diagnostics prepares the selected service request without replacing the device draft', () => {
  const { actions } = setup({
    terminal: deviceTerminal,
    services: [...base.services, { node: '2', type: 'research.server', instance: 'research.remote', stale: false }],
  });
  openPanel('Терминал');
  fireEvent.change(screen.getByRole('textbox', { name: 'Командная строка' }), {
    target: { value: 'self' },
  });
  openPanel('Карта');
  fireEvent.click(screen.getByText('Выбрать удалённый узел'));
  fireEvent.change(screen.getByLabelText('Сервис'), { target: { value: 'shell.remote' } });
  fireEvent.click(screen.getByText('Диагностика'));
  fireEvent.click(screen.getByText('Подготовить запрос API'));
  const presence = screen.getByRole('textbox', { name: 'Командная строка сети' }) as HTMLInputElement;
  expect(presence.value).toBe('api network.shell');
  expect(actions()).toEqual([]);
  fireEvent.keyDown(presence, { key: 'Enter' });
  expect(actions()).toEqual([{ type: 'act/act', payload: { line: 'api network.shell' } }]);
  fireEvent.change(screen.getByLabelText('Откуда выполнять'), { target: { value: 'device' } });
  const terminal = screen.getByRole('textbox', { name: 'Командная строка' }) as HTMLInputElement;
  expect(terminal.value).toBe('self');
  openPanel('Карта');
  expect((screen.getByLabelText('Сервис') as HTMLSelectElement).value).toBe('shell.remote');
});

test('selected map node offers an explicit Host route preview; Enter never skips preview', () => {
  const { push, actions } = setup();
  fireEvent.click(screen.getByText('Выбрать удалённый узел'));
  expect(screen.getByText(/Проверить переход/)).toBeTruthy();
  fireEvent.keyDown(document.body, { key: 'Enter' });
  expect(actions().filter(item => item.type === 'act/move')).toEqual([]);
  fireEvent.keyDown(document.body, { key: 'g' });
  expect(screen.getByRole('tab', { name: 'Маршруты' }).getAttribute('aria-selected')).toBe('true');
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
  fireEvent.keyDown(screen.getByLabelText('Настройки карты'), { key: 'Enter' });
  expect(actions().filter(item => item.type === 'act/move')).toEqual([]);
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
  fireEvent.click(screen.getByRole('tab', { name: 'Маршруты' }));
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
  const service = screen.getByRole('combobox', { name: 'Сервис' });
  fireEvent.change(service, { target: { value: 'shell.home' } });
  fireEvent.change(service, { target: { value: 'machine.switch' } });
  expect(actions()).toEqual([]);
  fireEvent.click(screen.getByText('Доступные действия'));
  expect(actions()).toEqual([{ type: 'act/act', payload: { line: 'api machine.control' } }]);
});

test('the vertical tab rail switches and focuses panels without sending commands', () => {
  const { actions } = setup();
  const node = screen.getByRole('tab', { name: 'Карта' });
  const routes = screen.getByRole('tab', { name: 'Маршруты' });
  node.focus();
  fireEvent.keyDown(node, { key: 'ArrowDown' });
  expect(document.activeElement).toBe(routes);
  expect(screen.getByRole('tabpanel', { name: 'Маршруты' }).id).toBe(routes.getAttribute('aria-controls'));
  expect(screen.queryByRole('tabpanel', { name: 'Карта' })).toBeNull();
  expect(actions()).toEqual([]);
});

test('a bodyless controller can explicitly leave the role', () => {
  const { actions } = setup({ entityRole: true });
  fireEvent.click(screen.getByText('Покинуть роль'));
  expect(actions()).toEqual([]);
  fireEvent.click(screen.getByText('Вернуться к призраку?'));
  expect(actions()).toEqual([{ type: 'act/leave_role', payload: {} }]);
});

test('toolbar selects scan radius and level independently of camera actions', () => {
  const { actions } = setup({ levels: [1, 2] });
  fireEvent.click(screen.getByLabelText('Настройки карты'));
  fireEvent.change(screen.getByRole('combobox', { name: 'Радиус сканирования' }), { target: { value: '5' } });
  fireEvent.click(screen.getByRole('button', { name: 'Сканировать' }));
  fireEvent.change(screen.getByRole('combobox', { name: 'Уровень карты' }), { target: { value: '2' } });
  fireEvent.click(screen.getByRole('button', { name: 'Я здесь' }));
  fireEvent.click(screen.getByRole('button', { name: 'Вся карта' }));
  expect(actions()).toEqual([
    { type: 'act/scan', payload: { radius: 5 } },
    { type: 'act/level', payload: { z: 2 } },
  ]);
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

test('optional enums show Host choices without the wire separator and can be left out', () => {
  const fields = (record: Record<string, string>) =>
    Object.entries(record).map(([name, value]) => ({ name, value }));
  const { actions } = setup({
    services: [{ node: '1', type: 'research.server', instance: 'research.lab', stale: false }],
    actionEntries: [
      {
        id: 1, line: 'api research.server', pending: false, status: 'ok',
        records: [fields({ type: 'research.server', command: 'status', request: 'research.status_request' })],
      },
      {
        id: 2, line: 'api research.server status', pending: false, status: 'ok',
        records: [fields({ how: 'request', field: 'reason', type: 'enum', required: 'no', spec: ' open|refresh' })],
      },
    ],
  });
  fireEvent.click(screen.getByText('Доступные действия'));
  fireEvent.click(screen.getByText('Получить состояние'));
  const reason = screen.getByRole('combobox', { name: 'Причина запроса' });
  expect(within(reason).getByRole('option', { name: 'Обновление' })).toBeTruthy();
  fireEvent.change(reason, { target: { value: 'refresh' } });
  fireEvent.click(screen.getByText('Отправить запрос'));
  fireEvent.change(reason, { target: { value: '' } });
  fireEvent.click(screen.getByText('Отправить запрос'));
  expect(actions().map(item => item.payload.line)).toEqual([
    'api research.server status', 'invoke research.lab status reason=refresh', 'invoke research.lab status',
  ]);
});

test('the panel API sends only the selected door action while the wire catalogue explains press', () => {
  const door = { node: '1', type: 'machine.door', instance: 'door.e24', stale: false };
  const { actions, push } = setup({
    services: [door],
    actionEntries: [{
      id: 1, line: 'api machine.door', pending: false, status: 'ok',
      records: ['set_state', 'control'].map((command, index) => [
        { name: 'type', value: 'machine.door' }, { name: 'command', value: command },
        { name: 'request', value: index === 0 ? 'machine.door_set' : 'machine.door_control_request' },
      ]),
    }],
  });
  expect(screen.queryByText('Панель шлюза')).toBeNull();
  fireEvent.click(screen.getByText('Доступные действия'));
  expect(screen.getByText(/идентификатор нажатия press/i)).toBeTruthy();
  expect(screen.queryByText('Изменить состояние')).toBeNull();
  expect(actions()).toEqual([]);
  push({ services: [{ ...door, doorPanel: { opened: 0, bolted: 0 } }] });
  fireEvent.click(screen.getByText('Панель шлюза', { selector: 'summary' }));
  fireEvent.click(screen.getByText('Открыть шлюз'));
  expect(actions()).toEqual([]);
  fireEvent.click(screen.getByText('Открыть шлюз?'));
  expect(actions()).toEqual([{ type: 'act/device_action', payload: { instance: 'door.e24', command: 'open' } }]);
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

test('receipt updates identify the actual service node without fabricating delivery', () => {
  const { push, actions } = setup();
  const entry = {
    id: 1, line: 'invoke shell.remote check', pending: false,
    status: 'ok', error: null, records: [],
  };
  push({ actionEntries: [entry] });
  expect(screen.getByTestId('delivery-signal').textContent).toBe('none');
  const delivery = { operation: '42', instance: 'shell.remote' };
  push({ actionEntries: [{ ...entry, delivery: { ...delivery, state: 'queued' } }] });
  expect(screen.getByTestId('delivery-signal').textContent).toBe('2:queued');
  fireEvent.click(screen.getByRole('tab', { name: 'События' }));
  expect(screen.getByText('В очереди')).toBeTruthy();
  push({ actionEntries: [{ ...entry, delivery: { ...delivery, state: 'delivered' } }] });
  expect(screen.getByTestId('delivery-signal').textContent).toBe('2:delivered');
  expect(screen.getByText('Ответ получен')).toBeTruthy();
  expect(actions()).toEqual([]);
});

test('camera discovery never selects a feed implicitly', () => {
  const { actions } = setup({
    services: [{ node: '2', instance: 'camera.7', type: 'camera.access', stale: false, cameraName: 'Бриг' }],
  });
  fireEvent.click(screen.getByText('Выбрать удалённый узел'));
  expect(actions()).toEqual([]);
  fireEvent.click(screen.getByText('Подключить на консоли'));
  expect(actions()).toEqual([{ type: 'act/select_camera', payload: { instance: 'camera.7' } }]);
});

test('APC breach displays a short pattern and submits the reconstructed answer once', () => {
  jest.useFakeTimers();
  try {
    const { push, actions } = setup();
    fireEvent.click(screen.getByText('Взломать АПЦ'));
    expect(actions()).toEqual([{ type: 'act/hack_start', payload: { node: '1' } }]);
    push({ hack: { target: '1', status: 'challenge', code: 'ABABCD', remaining: 14 } });
    const preview = within(screen.getByLabelText('Сигнал')).getAllByRole('img')
      .map(button => button.getAttribute('aria-label')!);
    expect(screen.queryByText('Ответить')).toBeNull();
    act(() => { jest.advanceTimersByTime(2400); });
    for (const label of preview) {
      fireEvent.click(within(screen.getByLabelText('Варианты сигнала')).getByRole('button', { name: label }));
    }
    fireEvent.click(screen.getByText('Ответить'));
    expect(actions().slice(1)).toEqual([{ type: 'act/hack_answer', payload: { code: 'ABABCD' } }]);
    expect(screen.queryByText('Ответить')).toBeNull();
  } finally {
    jest.useRealTimers();
  }
});
