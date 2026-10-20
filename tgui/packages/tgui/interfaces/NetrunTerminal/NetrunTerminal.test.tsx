import { act, fireEvent, render } from '@testing-library/react';
import { combineReducers, createStore, setGlobalStore } from 'common/redux';

import { backendReducer, backendUpdate } from '../../backend';
import { debugReducer } from '../../debug';
import { NetrunContent } from './Content';
import { FilePanel } from './FilePanel';
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
      breach: null, entity: null, chat: { handle: 'runner', messages: [] },
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
