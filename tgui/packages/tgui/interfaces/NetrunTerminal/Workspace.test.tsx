import { act, fireEvent, render, within } from '@testing-library/react';
import { combineReducers, createStore, setGlobalStore } from 'common/redux';

import { backendReducer, backendUpdate } from '../../backend';
import { debugReducer } from '../../debug';
import { NetrunContent } from './Content';
import { MatrixState, NetrunData, WorkspaceView } from './types';

const node = {
  address: 'TEST:0001', name: 'Сервер теста', type: 'server', x: 0, y: 0,
  security: 2, online: true, access: 2, legit: 2, entities: 0, active: false,
  uplink: null, network: 'test', commands: [], status: [],
};
const machine = {
  address: node.address, title: node.name, type: node.type, online: true,
  access: 2, fields: ['Состояние закреплённого сервера'], commands: [], extra: [],
  feed: null, watching: false, can_breach: true,
};
const breach: MatrixState = {
  minigame: 'automatic', target: 'BREACH TEST', security: 2, size: 0,
  cells: [], daemons: [], time_left: 18, progress: 0.3,
};

const setup = (overrides: Partial<NetrunData> = {}) => {
  const topic = jest.fn();
  (global as any).Byond = { winset: () => {}, topic };
  const store = createStore(combineReducers({ backend: backendReducer, debug: debugReducer }));
  setGlobalStore(store);
  store.dispatch(backendUpdate({ config: { interface: 'NetrunTerminal' }, data: {
    origin: 'terminal', workspace_view: 'terminal', wireless: false, uplink: true,
    trace: 0, locked: 0, can_breach: true, log: [], jack: null, host_actions: [],
    networks: [], view: null, selected: node, selected_network: null,
    storage: { files: [], used: 0, capacity: 10 }, shard: null, file: null,
    breach: null, entity: null, combat: null, chat: { handle: 'runner', messages: [] },
    web: null, windows: [], window: null, ping_route: null,
    map: { nodes: [node], edges: [], gateways: [], focus: node.address, revision: 1 },
    cli: { verbs: [{ id: 'help', args: '', desc: 'Справка' }] },
    ...overrides,
  } }));
  const panel = render(<NetrunContent />);
  const update = (data: Partial<NetrunData>) => {
    act(() => store.dispatch(backendUpdate({ data })));
    panel.rerender(<NetrunContent />);
  };
  const page = (id: WorkspaceView) => panel.container.querySelector<HTMLElement>(`[data-net-page="${id}"]`);
  return { topic, store, panel, update, page };
};

const actions = (topic, action: string) => topic.mock.calls
  .filter((call) => call[0]?.type === `act/${action}`)
  .map((call) => JSON.parse(call[0].payload));

describe('Netrun workspace pages', () => {
  let actionTime = Date.now();
  beforeEach(() => {
    actionTime += 1000;
    jest.spyOn(Date, 'now').mockReturnValue(actionTime);
  });
  afterEach(() => jest.restoreAllMocks());

  test('opens the terminal alone and gives every tool a dedicated workspace', () => {
    const { panel, page, topic } = setup();
    expect(panel.getByRole('tabpanel', { name: 'Терминал' })).toBeTruthy();
    expect(page('map').style.display).toBe('none');
    expect(page('files').style.display).toBe('none');
    expect(panel.container.querySelector('[data-net-layout="bottom"]')).toBeNull();
    expect(panel.container.querySelector('canvas[data-net-canvas]')).toBeNull();
    fireEvent.click(panel.getByText('Файлы'));
    expect(panel.getByRole('tabpanel', { name: 'Файлы' })).toBeTruthy();
    expect(page('terminal').style.display).toBe('none');
    expect(actions(topic, 'workspace_view')).toEqual([{ page: 'files' }]);
    expect(actions(topic, 'view_network')).toHaveLength(0);
  });

  test('reopening after a missed breach completion restores the terminal and corrects server mode once', () => {
    const { panel, update, topic } = setup({ workspace_view: 'breach', breach: null });
    expect(panel.getByRole('tabpanel', { name: 'Терминал' })).toBeTruthy();
    expect(panel.queryByText('Взлом')).toBeNull();
    expect(actions(topic, 'workspace_view')).toEqual([{ page: 'terminal' }]);
    // Allow another transport delivery so its duplicate guard cannot mask extra corrections.
    jest.spyOn(Date, 'now').mockReturnValue(actionTime + 1000);
    update({ workspace_view: 'breach', breach: null, log: [{ text: 'Очередное обновление', kind: 'label' }] });
    expect(panel.getByRole('tabpanel', { name: 'Терминал' })).toBeTruthy();
    expect(actions(topic, 'workspace_view')).toEqual([{ page: 'terminal' }]);
    update({ workspace_view: 'terminal' });
    expect(actions(topic, 'workspace_view')).toEqual([{ page: 'terminal' }]);
  });

  test('navigation preserves the command line, file draft, map filters and canvas instance', () => {
    const { panel, page, update } = setup();
    const cli = panel.getByPlaceholderText('help — список команд · ↑ история · Tab дополнение') as HTMLInputElement;
    fireEvent.change(cli, { target: { value: 'ping unfinished' } });
    fireEvent.click(panel.getByText('Файлы'));
    fireEvent.click(within(page('files')).getByText('Новый текстовый файл'));
    const editor = page('files').querySelector('textarea');
    fireEvent.change(editor, { target: { value: 'Несохранённый документ' } });
    fireEvent.click(panel.getByText('Карта'));
    const search = panel.getByPlaceholderText('поиск узла…') as HTMLInputElement;
    fireEvent.input(search, { target: { value: 'Сервер' } });
    const canvas = page('map').querySelector('canvas');
    fireEvent.click(panel.getByText('Терминал'));
    update({ workspace_view: 'terminal', map: null, selected: null });
    expect(cli.value).toBe('ping unfinished');
    expect(page('map').querySelector('canvas')).toBe(canvas);
    fireEvent.click(panel.getByText('Файлы'));
    expect(page('files').querySelector('textarea')).toBe(editor);
    expect(editor.value).toBe('Несохранённый документ');
    fireEvent.click(panel.getByText('Карта'));
    expect(panel.getByPlaceholderText('поиск узла…')).toBe(search);
    expect(search.value).toBe('Сервер');
  });

  test('opening a map node switches to pinned nodes and closing it keeps that page open', () => {
    const { panel, page, update, topic } = setup({ workspace_view: 'map' });
    const canvas = page('map').querySelector('canvas');
    fireEvent.click(panel.getByText('Показать информацию об узле'));
    fireEvent.click(within(page('map')).getByText('Закрепить'));
    expect(actions(topic, 'window_open')).toEqual([{ address: node.address }]);
    update({ workspace_view: 'pinned', map: null, selected: null, window: machine,
      windows: [{ address: node.address, title: node.name, type: node.type, online: true }] });
    expect(panel.getByRole('tabpanel', { name: 'Закреплённые узлы' })).toBeTruthy();
    expect(within(page('pinned')).getByText('Состояние закреплённого сервера')).toBeTruthy();
    expect(page('map').querySelector('canvas')).toBe(canvas);
    fireEvent.click(panel.getByTitle(`Закрыть закреплённый узел ${node.name}`));
    expect(actions(topic, 'window_close')).toEqual([{ address: node.address }]);
    update({ workspace_view: 'pinned', window: null, windows: [] });
    expect(panel.getByRole('tabpanel', { name: 'Закреплённые узлы' })).toBeTruthy();
    expect(within(page('pinned')).getByText(/Закреплённых узлов нет/)).toBeTruthy();
    fireEvent.click(panel.getByText('Карта'));
    expect(page('map').querySelector('canvas')).toBe(canvas);
  });

  test('an active breach has its own page while files and map retain their state', () => {
    const { panel, page, update, topic } = setup({ workspace_view: 'files' });
    fireEvent.click(within(page('files')).getByText('Новый текстовый файл'));
    const editor = page('files').querySelector('textarea');
    fireEvent.change(editor, { target: { value: 'Сохранить после взлома' } });
    update({ workspace_view: 'breach', breach, map: null, selected: null });
    expect(panel.getByRole('tabpanel', { name: 'Взлом' })).toBeTruthy();
    expect(within(page('breach')).getByText(/BREACH TEST/)).toBeTruthy();
    fireEvent.click(panel.getByText('Файлы'));
    expect(editor.value).toBe('Сохранить после взлома');
    expect(page('breach').style.display).toBe('none');
    fireEvent.click(panel.getByText('Взлом'));
    expect(panel.getByRole('tabpanel', { name: 'Взлом' })).toBeTruthy();
    update({ workspace_view: 'breach', breach: null });
    expect(panel.getByRole('tabpanel', { name: 'Файлы' })).toBeTruthy();
    expect(actions(topic, 'workspace_view').slice(-1)[0]).toEqual({ page: 'files' });
    expect(editor.value).toBe('Сохранить после взлома');
  });

  test('incoming attacks stay visible without replacing a draft and open a full combat page on demand', () => {
    const { panel, page, update, topic } = setup({ workspace_view: 'files' });
    fireEvent.click(within(page('files')).getByText('Новый текстовый файл'));
    const editor = page('files').querySelector('textarea');
    fireEvent.change(editor, { target: { value: 'Не терять фокус' } });
    update({ combat: { node: null, node_name: null, self: null, targets: [], programs: [],
      incoming: [{ source: 'ICE-SENTRY', source_ref: 'ice-1', name: 'trace.exe', role: 'trace', power: 6, remaining: 3 }] } });
    expect(panel.getByRole('tabpanel', { name: 'Файлы' })).toBeTruthy();
    expect(panel.getByRole('alert').textContent).toContain('ICE-SENTRY готовит trace.exe');
    expect(panel.getByRole('alert').style.position).not.toBe('absolute');
    fireEvent.click(panel.getByText('Открыть бой'));
    expect(panel.getByRole('tabpanel', { name: 'Бой' })).toBeTruthy();
    expect(actions(topic, 'workspace_view').slice(-1)[0]).toEqual({ page: 'combat' });
    expect(editor.value).toBe('Не терять фокус');
  });

  test('terminal chat is a subtab and WEB switches without closing pinned nodes', () => {
    const { panel, page, topic } = setup({
      window: machine, windows: [{ address: node.address, title: node.name, type: node.type, online: true }],
      web: { available: true, sites: [], site: null, page: null },
    });
    fireEvent.click(within(page('terminal')).getByText('#noosphere'));
    expect(within(page('terminal')).getByPlaceholderText('runner в #noosphere')).toBeTruthy();
    fireEvent.click(panel.getByText('WEB'));
    expect(panel.getByRole('tabpanel', { name: 'WEB' })).toBeTruthy();
    expect(actions(topic, 'workspace_view')).toEqual([{ page: 'web' }]);
    expect(actions(topic, 'window_close')).toHaveLength(0);
    fireEvent.click(panel.getByText('Терминал'));
    expect(within(page('terminal')).getByPlaceholderText('runner в #noosphere')).toBeTruthy();
  });
});
