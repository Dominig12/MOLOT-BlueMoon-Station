import { act, fireEvent, render } from '@testing-library/react';
import { combineReducers, createStore, setGlobalStore } from 'common/redux';

import { backendReducer, backendUpdate } from '../../backend';
import { debugReducer } from '../../debug';
import { CombatPanel } from './CombatPanel';
import { NetrunContent } from './Content';
import { FilePanel } from './FilePanel';
import * as mapGeometry from './mapLayout';
import { MatrixPanel } from './Matrix';
import { StationMap } from './NetworkMap';
import { NodePanel } from './NodePanel';
import { ConsoleLog } from './Panels';
import { GraphViewport } from './graphViewport';
import { NetrunData } from './types';
import { WindowPanel } from './WindowPanel';

const command = {
  id: 'apc_breaker', name: 'Главный рубильник', desc: 'Переключить питание.',
  icon: 'power-off', danger: false, access: 2, allowed: true,
  illegal: false, trace: 0,
};

const node = {
  address: 'AAAA:0001', name: 'APC инженерии', type: 'apc', x: 10, y: 10,
  security: 2, online: true, access: 2, entities: 0, active: false,
  uplink: null, network: 'engineering', legit: 2, commands: [command], status: ['Заряд 75%'],
};

const machine = {
  address: node.address, title: node.name, type: node.type,
  online: true, access: 2, fields: node.status, commands: [command],
  extra: [], feed: null, watching: false, can_breach: true,
};

const setup = (overrides: Partial<NetrunData> = {}) => {
  const topic = jest.fn();
  (global as any).Byond = { winset: () => {}, topic };
  const store = createStore(combineReducers({ backend: backendReducer, debug: debugReducer }));
  setGlobalStore(store);
  store.dispatch(backendUpdate({
    config: { interface: 'NetrunTerminal' },
    data: {
      origin: 'terminal', wireless: false, uplink: true, trace: 0,
      locked: 0, can_breach: true, log: [], jack: null, host_actions: [],
      networks: [], view: null, selected: node,
      storage: { files: [], used: 0, capacity: 10 }, shard: null,
      breach: null, entity: null, combat: null, chat: { handle: 'runner', messages: [] },
      web: null, windows: [], window: null,
      map: { gateways: [], focus: node.address, revision: 1,
        nodes: [node, { ...node, address: 'BBBB:0002', x: 20 }],
        edges: [{ id: 'apc-link', from: node.address, to: 'BBBB:0002', kind: 'apc' }] },
      selected_network: null, ping_route: null,
      cli: { verbs: [{ id: 'sel', args: '<адрес>', desc: 'Выбрать узел.' }] },
      ...overrides,
    },
  }));
  return Object.assign(topic, { store });
};

const sent = (topic, action: string) => topic.mock.calls
  .filter((call) => call[0]?.type === `act/${action}`)
  .map((call) => JSON.parse(call[0].payload));

describe('Netrun terminal panels', () => {
  test('arrange then manual pan is preserved when a later structural update arrives', () => {
    const originalPointer = window.PointerEvent;
    Object.defineProperty(window, 'PointerEvent', { value: MouseEvent, configurable: true });
    const fit = jest.spyOn(GraphViewport.prototype, 'fit');
    const topic = setup();
    const { getByText, getByLabelText, rerender } = render(<StationMap />);
    fireEvent.click(getByText('Упорядочить'));
    const viewport = getByLabelText('Карта сети');
    fireEvent.pointerDown(viewport, { clientX: 100, clientY: 100, button: 0 });
    fireEvent.pointerMove(viewport, { clientX: 150, clientY: 150 });
    fireEvent.pointerUp(viewport, { clientX: 150, clientY: 150 });
    const before = fit.mock.calls.length;
    const map = topic.store.getState().backend.data.map;
    act(() => topic.store.dispatch(backendUpdate({ data: { map: { ...map, revision: 2,
      nodes: [...map.nodes, { ...node, address: 'NEW', type: 'camera', uplink: node.address }],
      edges: [...map.edges, { id: 'new', from: node.address, to: 'NEW', kind: 'endpoint' }] } } })));
    rerender(<StationMap />);
    expect(fit).toHaveBeenCalledTimes(before);
    fit.mockRestore();
    Object.defineProperty(window, 'PointerEvent', { value: originalPointer, configurable: true });
  });

  test('projected state revisions repaint without layout and structural revisions replace nodes and links', () => {
    const layout = jest.spyOn(mapGeometry, 'layoutGraph');
    const initial = { gateways: [], focus: node.address, revision: 1, structure_revision: 4, state_revision: 10,
      nodes: [node], edges: [] };
    const topic = setup({ map: initial });
    const { getByText, rerender } = render(<StationMap />);
    expect(layout).toHaveBeenCalledTimes(1);
    act(() => topic.store.dispatch(backendUpdate({ data: { map: { ...initial, state_revision: 11, nodes: [{ ...node, online: false }] } } })));
    rerender(<StationMap />);
    expect(layout).toHaveBeenCalledTimes(1);
    const added = { ...node, address: 'NEW', type: 'camera', uplink: node.address };
    act(() => topic.store.dispatch(backendUpdate({ data: { map: { ...initial, structure_revision: 5, state_revision: 12,
      nodes: [node, added], edges: [{ id: 'new-link', from: node.address, to: 'NEW', kind: 'endpoint' }] } } })));
    rerender(<StationMap />);
    expect(getByText('2/2 · вся доступная сеть')).toBeTruthy();
    expect(layout).toHaveBeenCalledTimes(2);
    fireEvent.click(getByText('Упорядочить'));
    expect(layout).toHaveBeenCalledTimes(3);
    act(() => topic.store.dispatch(backendUpdate({ data: { map: { ...initial, structure_revision: 6, state_revision: 13 } } })));
    rerender(<StationMap />);
    expect(getByText('1/1 · вся доступная сеть')).toBeTruthy();
    expect(layout).toHaveBeenCalledTimes(4);
    layout.mockRestore();
  });

  test('automatic breach explicitly sends its mode and shows waiting progress instead of cells', () => {
    const topic = setup({ can_autobreach: true, selected: { ...node, access: 1 } });
    const panel = render(<NodePanel />);
    fireEvent.click(panel.getByText('Автовзлом'));
    expect(sent(topic, 'breach')).toContainEqual({ kind: 'node', id: node.address, automatic: true });
    panel.unmount();
    const { getByText } = render(<MatrixPanel state={{ minigame: 'automatic', target: 'test node', security: 3,
      size: 0, cells: [], daemons: [], time_left: 18, progress: 0.4 }} />);
    expect(getByText(/Подбор доступа: 40%/)).toBeTruthy();
    fireEvent.click(getByText('Прервать взлом'));
    expect(sent(topic, 'breach_abort')).toHaveLength(1);
  });

  test('incoming ICE warning remains visible over an active breach puzzle', () => {
    setup({ combat: { node: node.address, node_name: node.name, self: null, targets: [], programs: [],
      incoming: [{ source: 'ICE-SENTRY', name: 'strike.exe', role: 'attack', power: 18, remaining: 2.5 }] },
    breach: { minigame: 'automatic', target: node.name, security: 2, size: 0, cells: [], daemons: [], time_left: 18, progress: 0.3 } });
    const { getByRole, getByText } = render(<NetrunContent />);
    expect(getByRole('alert').textContent).toContain('ICE-SENTRY готовит strike.exe');
    expect(getByRole('alert').textContent).toContain('2.5 с');
    expect(getByText('Открыть бой')).toBeTruthy();
  });

  test('recoverable daemon loot is shown even without a living combat target', () => {
    const topic = setup({ combat: { node: node.address, node_name: node.name,
      self: { integrity: 100, max_integrity: 100, stunned: false }, targets: [], programs: [],
      loot: [{ uid: 'salvage-1', name: 'autobreach.exe', kind: 'daemon', size: 3, preview: null }] } });
    const { getByText } = render(<CombatPanel />);
    expect(getByText(/autobreach.exe/)).toBeTruthy();
    fireEvent.click(getByText('Забрать'));
    expect(sent(topic, 'recover_salvage')).toEqual([{ uid: 'salvage-1' }]);
  });

  test('stored route generations update status and overlay without recomputing graph geometry', () => {
    const layout = jest.spyOn(mapGeometry, 'layoutGraph');
    const topic = setup();
    const map = topic.store.getState().backend.data.map;
    const route = { route: [node.address, 'BBBB:0002'], hops: 1, latency: 300, revision: 7, reachable: true };
    act(() => topic.store.dispatch(backendUpdate({ data: { map: { ...map, route } } })));
    const { container, getByText, getByTitle, rerender } = render(<StationMap />);
    expect(getByText('Путь: 1 пер. · 300 мс')).toBeTruthy();
    expect(container.querySelector('canvas[data-net-canvas]')).not.toBeNull();
    expect(layout).toHaveBeenCalledTimes(1);
    act(() => topic.store.dispatch(backendUpdate({ data: { map: { ...map, route: { ...route, revision: 8, latency: 400 } } } })));
    rerender(<StationMap />);
    expect(getByText('Путь: 1 пер. · 400 мс')).toBeTruthy();
    expect(getByTitle('Сохранённый маршрут #8')).toBeTruthy();
    expect(layout).toHaveBeenCalledTimes(1);
    act(() => topic.store.dispatch(backendUpdate({ data: { map: { ...map, route: { ...route, revision: 9, reachable: false } } } })));
    rerender(<StationMap />);
    expect(getByText('Путь: нет связи')).toBeTruthy();
    expect(container.querySelectorAll('canvas[data-net-canvas]')).toHaveLength(1);
    layout.mockRestore();
  });

  test('a stored path never draws a shortcut across missing intermediate vertices', () => {
    const topic = setup();
    const map = topic.store.getState().backend.data.map;
    act(() => topic.store.dispatch(backendUpdate({ data: { map: { ...map, route: {
      route: [node.address, 'NOT-IN-SLICE', 'BBBB:0002'], hops: 2, latency: 500, revision: 1, reachable: true,
    } } } })));
    const { container, getByText } = render(<StationMap />);
    expect(getByText('Путь: 2 пер. · 500 мс')).toBeTruthy();
    expect(container.querySelectorAll('canvas[data-net-canvas]')).toHaveLength(1);
  });

  test('log polling reuses layout and a suspended map does not inspect replacement payloads', () => {
    const layout = jest.spyOn(mapGeometry, 'layoutGraph');
    const topic = setup();
    const { rerender } = render(<StationMap />);
    expect(layout).toHaveBeenCalledTimes(1);
    const currentMap = topic.store.getState().backend.data.map;
    act(() => topic.store.dispatch(backendUpdate({ data: {
      map: { ...currentMap, nodes: currentMap.nodes.map((entry) => ({ ...entry })) },
      trace: 15, log: [{ text: 'New log entry', kind: 'label' }],
    } })));
    rerender(<StationMap />);
    expect(layout).toHaveBeenCalledTimes(1);
    rerender(<StationMap suspended />);
    const replacement = Object.defineProperty({ ...currentMap }, 'nodes', {
      get: () => { throw new Error('A suspended map must not read the graph'); },
    });
    act(() => topic.store.dispatch(backendUpdate({ data: { map: replacement } })));
    rerender(<StationMap suspended />);
    expect(layout).toHaveBeenCalledTimes(1);
    layout.mockRestore();
  });

  test('workspace and map consume available height and remote file controls stay in aligned scrolling rows', () => {
    setup({ selected: { ...node, access: 3, files: [
      { uid: 'text', name: 'Очень длинное имя файла с заметкой для передачи.txt', kind: 'text', size: 1, preview: null },
      { uid: 'photo', name: 'Фото.png', kind: 'photo', size: 2, preview: null },
    ] } });
    const { container } = render(<NetrunContent />);
    const workspace = container.querySelector<HTMLElement>('[data-net-layout="workspace"]');
    const map = container.querySelector<HTMLElement>('[data-net-layout="map"]');
    expect(workspace.style.flex).toContain('1 1');
    expect(map.style.height).toBe('100%');
    expect(container.querySelector<HTMLElement>('[aria-label="Карта сети"]').style.flex).toContain('1 1');
    const files = container.querySelector<HTMLElement>('[data-net-files="remote"]');
    expect(files.style.overflowY).toBe('auto');
    const rows = [...files.querySelectorAll<HTMLElement>('[data-net-file-row]')];
    expect(rows.length).toBe(2);
    for (const row of rows) {
      // Actions sit in a horizontal flex row, not a vertical column.
      const actions = row.querySelector<HTMLElement>('[data-net-file-actions]');
      expect(actions.style.display).toBe('flex');
      expect(actions.style.flexWrap).toBe('wrap');
    }
  });

  test('map filters and local search exclude vertices without rebuilding topology', () => {
    const camera = { ...node, address: 'CAM:0001', name: 'Камера лаборатории', type: 'camera', x: 20 };
    const topic = setup({ map: { gateways: [], focus: node.address, revision: 1,
      nodes: [node, camera], edges: [{ id: 'camera-link', from: camera.address, to: node.address, kind: 'endpoint' }] } });
    const { getByLabelText, getByPlaceholderText, getByText } = render(<StationMap />);
    expect(getByText('2/2 · вся доступная сеть')).toBeTruthy();
    fireEvent.click(getByLabelText('Фильтр: Камеры'));
    expect(getByText('1/2 · вся доступная сеть')).toBeTruthy();
    fireEvent.keyDown(getByLabelText('Карта сети'), { key: 'd' });
    expect(sent(topic, 'select')).toEqual([]);
    fireEvent.click(getByLabelText('Фильтр: Камеры'));
    expect(getByText('2/2 · вся доступная сеть')).toBeTruthy();
    const input = getByPlaceholderText('поиск узла…');
    fireEvent.input(input, { target: { value: 'лаборатории' } });
    expect(getByText('1/2 · вся доступная сеть')).toBeTruthy();
    fireEvent.input(input, { target: { value: 'несуществующий узел' } });
    expect(getByText('0/2 · вся доступная сеть')).toBeTruthy();
    fireEvent.input(input, { target: { value: '' } });
    expect(getByText('2/2 · вся доступная сеть')).toBeTruthy();
  });

  test('large network renders with a single Canvas, regardless of number of vertices', () => {
    const large = Array.from({ length: 1100 }, (_, i) => ({ ...node, address: `CLIENT-${i}`, type: 'camera', uplink: node.address }));
    const edges = large.map((n) => ({ id: n.address, from: n.address, to: node.address, kind: 'endpoint' as const }));
    setup({ map: { gateways: [], focus: node.address, revision: 1, nodes: [node, ...large], edges } });
    const { container, getByText } = render(<StationMap />);
    expect(getByText('1101/1101 · вся доступная сеть')).toBeTruthy();
    expect(container.querySelectorAll('canvas[data-net-canvas]')).toHaveLength(1);
    expect(container.querySelectorAll('[data-net-node]')).toHaveLength(0);
    expect(container.querySelectorAll('[data-net-edge]')).toHaveLength(0);
  });

  test('server tile coordinates cannot move a stable map layout', () => {
    const map = {
      nodes: [node, { ...node, address: 'CAM', type: 'camera', uplink: node.address }],
      edges: [{ id: 'endpoint', from: 'CAM', to: node.address, kind: 'endpoint' as const }],
      gateways: [], focus: node.address, revision: 1,
    };
    const cache = mapGeometry.createGraphLayoutCache();
    const before = mapGeometry.layoutGraph(map.nodes, map.edges, cache);
    const movedTiles = map.nodes.map((n) => ({ ...n, x: -9999, y: 9999, z: 4 }));
    const after = mapGeometry.layoutGraph(movedTiles, map.edges, cache);
    expect(after).toEqual(before);
    setup({ map });
    const { container } = render(<StationMap />);
    expect(container.querySelectorAll('canvas[data-net-canvas]')).toHaveLength(1);
  });

  test('node commands have natural height and dispatch the selected command', () => {
    const topic = setup();
    const { container, getByText } = render(<NodePanel />);
    expect(container.querySelector('.Section--fill')).toBeNull();
    expect(getByText('Заряд 75%')).toBeTruthy();
    fireEvent.click(getByText(command.name));
    expect(sent(topic, 'command')).toEqual([{ id: command.id }]);
  });

  test('machine tab shows commands, breach and native actions without parameters', () => {
    const topic = setup();
    const { container, getByText } = render(<WindowPanel window={{
      ...machine,
      remote: { interface: 'PortableTurret', data: { enabled: true }, actions: [
        { id: 'power', name: 'Питание турели', access: 3, allowed: true },
      ] },
    }} />);
    expect(container.querySelector('.Section--fill')).toBeNull();
    fireEvent.click(getByText(command.name));
    expect(sent(topic, 'window_act')).toEqual([{ address: node.address, waction: command.id }]);
    fireEvent.click(getByText('Подобрать доступ к узлу'));
    expect(sent(topic, 'breach')).toEqual([{ kind: 'node', id: node.address }]);
    fireEvent.click(getByText('Питание турели'));
    expect(sent(topic, 'remote_act')).toEqual([{ address: node.address, request: 'power', arguments: {} }]);
  });

  test('matrix remains visible when a machine tab starts a breach', () => {
    setup({
      window: machine,
      windows: [{ address: node.address, title: node.name, type: node.type, online: true }],
      breach: {
        target: 'BREACH APC', security: 2, size: 1,
        cells: [{ code: '1C', active: true }], buffer: [], buffer_size: 4,
        daemons: [], time_left: 20, pick_row: true,
      },
    });
    const { getByText, queryByText } = render(<NetrunContent />);
    expect(getByText('BREACH APC')).toBeTruthy();
    expect(queryByText('Запросы')).toBeNull();
  });

  test('Tab completes addresses from the unified map', () => {
    setup();
    const { getByPlaceholderText } = render(<ConsoleLog />);
    const input = getByPlaceholderText('help — список команд · ↑ история · Tab дополнение') as HTMLInputElement;
    fireEvent.change(input, { target: { value: 'sel BBB' } });
    fireEvent.keyDown(input, { key: 'Tab' });
    expect(input.value).toBe('sel BBBB:0002');
    fireEvent.change(input, { target: { value: 'sel AAAA:000' } });
    fireEvent.keyDown(input, { key: 'Tab' });
    expect(input.value).toBe('sel AAAA:0001');
  });

  test('history keeps twenty commands and restores the unfinished draft', () => {
    setup();
    const { getByPlaceholderText } = render(<ConsoleLog />);
    const input = getByPlaceholderText('help — список команд · ↑ история · Tab дополнение') as HTMLInputElement;
    for (let i = 0; i < 21; i++) {
      fireEvent.change(input, { target: { value: `cmd${i}` } });
      fireEvent.keyDown(input, { key: 'Enter' });
    }
    fireEvent.change(input, { target: { value: 'draft' } });
    for (let i = 0; i < 25; i++) {
      fireEvent.keyDown(input, { key: 'ArrowUp' });
    }
    expect(input.value).toBe('cmd1');
    for (let i = 0; i < 20; i++) {
      fireEvent.keyDown(input, { key: 'ArrowDown' });
    }
    expect(input.value).toBe('draft');
  });

  test('map keyboard navigation requires map focus and entity hops start at its host', () => {
    const topic = setup({
      selected: { ...node, address: 'Z-SELECTED' },
      entity: { name: 'Process', integrity: 100, max_integrity: 100, host: 'A-HOST', host_name: 'Host', diving: false },
      map: { gateways: [], focus: 'A-HOST', revision: 1, nodes: [
        { ...node, address: 'Z-SELECTED' }, { ...node, address: 'A-HOST' },
        { ...node, address: 'B-LOCKED', access: 1 }, { ...node, address: 'C-OFFLINE', online: false },
        { ...node, address: 'D-TARGET' }, { ...node, address: 'E-NONNEIGHBOR' },
      ], edges: [
        { id: 'locked', from: 'A-HOST', to: 'B-LOCKED', kind: 'apc' },
        { id: 'offline', from: 'A-HOST', to: 'C-OFFLINE', kind: 'apc' },
        { id: 'target', from: 'A-HOST', to: 'D-TARGET', kind: 'apc' },
        { id: 'indirect', from: 'B-LOCKED', to: 'E-NONNEIGHBOR', kind: 'apc' },
      ] },
    });
    const { getByLabelText, getByPlaceholderText } = render(<StationMap />);
    fireEvent.keyDown(getByPlaceholderText('поиск узла…'), { key: 'd', shiftKey: true });
    expect(sent(topic, 'hop')).toEqual([]);
    const canvas = getByLabelText('Карта сети');
    fireEvent.keyDown(canvas, { key: 'd', shiftKey: true });
    expect(sent(topic, 'hop')).toEqual([{ address: 'D-TARGET' }]);
  });

  test('a LAN key permits a guest to hop without enabling machine commands', () => {
    const host = { ...node, address: 'A-HOST' };
    const keyed = { ...node, address: 'KEY-CLIENT', type: 'camera', uplink: host.address,
      access: 1, legit: 1, can_hop: true, commands: [{ ...command, allowed: false }] };
    const topic = setup({ selected: keyed,
      entity: { name: 'Process', integrity: 100, max_integrity: 100, host: host.address, host_name: 'Host', diving: false },
      map: { nodes: [host, keyed], edges: [{ id: 'keyed-neighbor', from: host.address, to: keyed.address, kind: 'endpoint' }],
        gateways: [], focus: host.address, revision: 1 },
    });
    const { getByLabelText, getByText } = render(<><StationMap /><NodePanel /></>);
    expect(getByText(command.name).closest('.Button').classList.contains('Button--disabled')).toBe(true);
    const hop = getByText('Перейти в узел');
    expect(hop.closest('.Button').classList.contains('Button--disabled')).toBe(false);
    fireEvent.click(hop);
    fireEvent.keyDown(getByLabelText('Карта сети'), { key: 's', shiftKey: true });
    // The transport intentionally deduplicates identical actions within 50 ms.
    expect(sent(topic, 'hop')).toEqual([{ address: keyed.address }]);
    fireEvent.click(getByText(command.name));
    expect(sent(topic, 'command')).toEqual([]);
  });

  test('a rejected file creation and later polling preserve the entire draft', () => {
    const topic = setup({ file: null, storage: { files: [], used: 6, capacity: 6 } });
    const { container, getByText, rerender } = render(<FilePanel />);
    fireEvent.click(getByText('Новый текстовый файл'));
    const draft = 'Новый документ, который пока не помещается в память.';
    fireEvent.change(container.querySelector('textarea'), { target: { value: draft } });
    fireEvent.click(getByText('Создать'));
    expect(sent(topic, 'file_new')).toEqual([{ name: 'note.txt', content: draft, to_shard: false }]);
    act(() => {
      topic.store.dispatch(backendUpdate({ data: { file: null } }));
    });
    rerender(<FilePanel />);
    expect(container.querySelector('textarea')?.value).toBe(draft);
    expect(getByText('Создать')).toBeTruthy();
  });
});
