import { act, fireEvent, render } from '@testing-library/react';
import { combineReducers, createStore, setGlobalStore } from 'common/redux';

import { backendReducer, backendUpdate } from '../../backend';
import { debugReducer } from '../../debug';
import { CombatPanel } from './CombatPanel';
import { NetrunContent } from './Content';
import { FilePanel } from './FilePanel';
import { MatrixPanel } from './Matrix';
import * as mapGeometry from './mapLayout';
import { StationMap } from './NetworkMap';
import { NodePanel } from './NodePanel';
import { ConsoleLog } from './Panels';
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
      map: { gateways: [], focus: node.address, depth: 2, revision: 1,
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
    expect(container.querySelector('[data-net-overlay="selected-route"]')).not.toBeNull();
    expect(layout).toHaveBeenCalledTimes(1);
    act(() => topic.store.dispatch(backendUpdate({ data: { map: { ...map, route: { ...route, revision: 8, latency: 400 } } } })));
    rerender(<StationMap />);
    expect(getByText('Путь: 1 пер. · 400 мс')).toBeTruthy();
    expect(getByTitle('Сохранённый маршрут #8')).toBeTruthy();
    expect(layout).toHaveBeenCalledTimes(1);
    act(() => topic.store.dispatch(backendUpdate({ data: { map: { ...map, route: { ...route, revision: 9, reachable: false } } } })));
    rerender(<StationMap />);
    expect(getByText('Путь: нет связи')).toBeTruthy();
    expect(container.querySelector('[data-net-overlay="selected-route"]')).toBeNull();
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
    expect(container.querySelector('[data-net-overlay="selected-route"]')).toBeNull();
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
      expect(row.style.gridTemplateColumns).toBe('minmax(0, 1fr) 28px');
      expect(row.querySelector<HTMLElement>('[data-net-file-actions]').style.gridTemplateColumns).toBe('28px');
    }
  });

  test('map filters remove hidden nodes and keyboard targets without moving other nodes', () => {
    const camera = { ...node, address: 'CAM:0001', name: 'Камера лаборатории', type: 'camera', x: 20 };
    const topic = setup({ map: { gateways: [], focus: node.address, depth: 2, revision: 1,
      nodes: [node, camera], edges: [{ id: 'camera-link', from: camera.address, to: node.address, kind: 'endpoint' }] } });
    const { getByLabelText, getByPlaceholderText, getByTitle, queryByTitle } = render(<StationMap />);
    const apcTitle = `${node.name} ${node.address} — Щитки APC`;
    const cameraTitle = `${camera.name} ${camera.address} — Камеры`;
    const originalStyle = getByTitle(apcTitle).getAttribute('style');
    fireEvent.click(getByLabelText('Фильтр: Камеры'));
    expect(queryByTitle(cameraTitle)).toBeNull();
    expect(getByTitle(apcTitle).getAttribute('style')).toBe(originalStyle);
    fireEvent.keyDown(getByLabelText('Карта сети'), { key: 'd' });
    expect(sent(topic, 'select')).toEqual([]);
    fireEvent.click(getByLabelText('Фильтр: Камеры'));
    expect(getByTitle(cameraTitle)).toBeTruthy();
    const input = getByPlaceholderText('поиск узла…');
    fireEvent.input(input, { target: { value: 'лаборатории' } });
    expect(queryByTitle(apcTitle)).toBeNull();
    expect(getByTitle(cameraTitle)).toBeTruthy();
    fireEvent.input(input, { target: { value: 'несуществующий узел' } });
    expect(queryByTitle(cameraTitle)).toBeNull();
    fireEvent.input(input, { target: { value: '' } });
    expect(getByTitle(apcTitle).getAttribute('style')).toBe(originalStyle);
  });

  test('map draws exactly the published links and one parent for an endpoint', () => {
    const map = {
      gateways: [{ id: 'engineering', code: 'NET-ENG', name: 'Инженерия', color: '#ffaa00', security: 2, access: 2, has_key: false, can_breach: false }],
      focus: node.address, depth: 2, revision: 1,
      nodes: [node, { ...node, address: 'APC-B' }, { ...node, address: 'CAM', type: 'camera', uplink: node.address }, { ...node, address: 'RELAY', type: 'gateway' }],
      edges: [
        { id: 'endpoint', from: 'CAM', to: node.address, kind: 'endpoint' as const },
        { id: 'chain', from: node.address, to: 'APC-B', kind: 'apc' as const },
        { id: 'relay', from: 'RELAY', to: 'APC-B', kind: 'relay' as const },
      ],
    };
    const topic = setup({ map });
    const { container, getByText, rerender } = render(<StationMap />);
    expect(container.querySelectorAll('[data-net-edge]').length).toBe(3);
    expect(container.querySelectorAll('[data-from="CAM"]').length).toBe(1);
    expect(container.querySelector('[data-from="CAM"]').getAttribute('data-to')).toBe(node.address);
    expect(container.querySelectorAll('svg text').length).toBe(0);
    expect(getByText('NET-ENG')).toBeTruthy();
    const before = container.querySelector('[data-net-node="CAM"]').getAttribute('style');
    act(() => topic.store.dispatch(backendUpdate({ data: { map: { ...map, revision: 2, nodes: map.nodes.map((entry) => ({ ...entry, x: -9999, y: 9999, z: 4 })) } } })));
    rerender(<StationMap />);
    expect(container.querySelector('[data-net-node="CAM"]').getAttribute('style')).toBe(before);
  });

  test('SVG and markers share dynamic bounds when a backbone extends beyond the old fixed canvas', () => {
    const chain = Array.from({ length: 12 }, (_, index) => ({ ...node, address: `APC-${String(index).padStart(2, '0')}` }));
    const edges = chain.slice(1).map((entry, index) => ({ id: `edge-${index}`, from: chain[index].address, to: entry.address, kind: 'apc' as const }));
    setup({ selected: { ...chain[0] }, map: { nodes: chain, edges, gateways: [], focus: chain[0].address, depth: 12, revision: 1 } });
    const { container } = render(<StationMap />);
    const svg = container.querySelector('svg');
    const [minX, minY, width, height] = svg.getAttribute('viewBox').split(' ').map(Number);
    expect(Number(svg.getAttribute('width'))).toBeGreaterThan(2000);
    for (const line of container.querySelectorAll('[data-net-edge]')) {
      for (const coordinate of ['x1', 'x2']) {
        expect(Number(line.getAttribute(coordinate))).toBeGreaterThan(minX);
        expect(Number(line.getAttribute(coordinate))).toBeLessThan(minX + width);
      }
      for (const coordinate of ['y1', 'y2']) {
        expect(Number(line.getAttribute(coordinate))).toBeGreaterThan(minY);
        expect(Number(line.getAttribute(coordinate))).toBeLessThan(minY + height);
      }
    }
    const canvas = container.querySelector<HTMLElement>('[data-net-canvas]');
    const marker = container.querySelector<HTMLElement>('[data-net-node="APC-11"]');
    const edge = container.querySelector('[data-to="APC-11"]');
    expect(parseFloat(canvas.style.left) + parseFloat(marker.style.left)).toBe(Number(edge.getAttribute('x2')));
    expect(parseFloat(canvas.style.top) + parseFloat(marker.style.top)).toBe(Number(edge.getAttribute('y2')));
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
      map: { gateways: [], focus: 'A-HOST', depth: 2, revision: 1, nodes: [
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
        gateways: [], focus: host.address, depth: 2, revision: 1 },
    });
    const { getByLabelText, getByText } = render(<><StationMap /><NodePanel /></>);
    expect(getByText(command.name).closest('.Button').classList.contains('Button--disabled')).toBe(true);
    const hop = getByText('Перейти в узел');
    expect(hop.closest('.Button').classList.contains('Button--disabled')).toBe(false);
    fireEvent.click(hop);
    fireEvent.keyDown(getByLabelText('Карта сети'), { key: 's', shiftKey: true });
    expect(sent(topic, 'hop')).toEqual([{ address: keyed.address }, { address: keyed.address }]);
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
