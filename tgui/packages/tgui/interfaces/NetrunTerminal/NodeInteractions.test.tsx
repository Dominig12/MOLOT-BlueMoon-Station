import { act, fireEvent, render, within } from '@testing-library/react';
import { combineReducers, createStore, setGlobalStore } from 'common/redux';

import { backendReducer, backendUpdate } from '../../backend';
import { debugReducer } from '../../debug';
import { NetrunContent } from './Content';
import { NodePanel } from './NodePanel';
import { EntityContact, NetrunData, SelectedNode } from './types';

const contact: EntityContact = {
  ref: 'process-1', name: 'Резидент', kind: 'entity', integrity: 80,
  max_integrity: 100, state: 'Ожидает', self: false, can_signal: true, can_message: true,
};
const node: SelectedNode = {
  address: 'LAN:0001', name: 'Терминал', type: 'terminal', x: 1, y: 1,
  security: 2, online: true, access: 2, legit: 2, entities: 1,
  active: false, uplink: null, network: 'LAN', commands: [], status: [],
  interactions: [{ id: 'dive', name: 'Погрузиться в узел', icon: 'plug', enabled: true }],
  contacts: [contact],
};

const setup = (overrides: Partial<NetrunData> = {}) => {
  const topic = jest.fn();
  (global as any).Byond = { winset: () => {}, topic };
  const store = createStore(combineReducers({ backend: backendReducer, debug: debugReducer }));
  setGlobalStore(store);
  store.dispatch(backendUpdate({ config: { interface: 'NetrunTerminal' }, data: {
    workspace_view: 'map', origin: 'implant', wireless: true, uplink: true,
    trace: 0, locked: 0, can_breach: false, log: [], jack: null, host_actions: [],
    networks: [], selected: node, selected_network: null,
    map: { gateways: [], nodes: [node], edges: [], revision: 1, focus: node.address },
    storage: { files: [], used: 0, capacity: 6 }, shard: null,
    breach: null, entity: null, combat: null, chat: { handle: 'runner', messages: [] },
    web: null, windows: [], window: null, ...overrides,
  } }));
  return { store, topic };
};

const sent = (topic, action: string) => topic.mock.calls
  .filter((call) => call[0]?.type === `act/${action}`)
  .map((call) => {
    const { _netrun_action: _receipt, ...payload } = JSON.parse(call[0].payload);
    return payload;
  });

describe('Node and process interactions', () => {
  test('the selected entry exposes dive and reacts to revoked availability', () => {
    const { store, topic } = setup();
    const panel = render(<NodePanel />);
    fireEvent.click(panel.getByText('Погрузиться в узел'));
    expect(sent(topic, 'node_interact')).toEqual([{ id: 'dive' }]);
    act(() => store.dispatch(backendUpdate({ data: { selected: {
      ...node, interactions: [{ ...node.interactions![0], enabled: false, reason: 'Узел больше не отвечает.' }],
    } } })));
    expect(panel.getByText('Узел больше не отвечает.')).toBeTruthy();
    fireEvent.click(panel.getByText('Погрузиться в узел'));
    expect(sent(topic, 'node_interact')).toHaveLength(1);
  });

  test('a suspended map keeps details visible while disabling entry and contact actions', () => {
    const { store, topic } = setup();
    const panel = render(<NodePanel />);
    act(() => store.dispatch(backendUpdate({ data: { workspace_view: 'terminal', selected: null, map: null } })));
    fireEvent.click(panel.getByText('Погрузиться в узел'));
    fireEvent.click(panel.getByText('Послать сигнал'));
    expect(sent(topic, 'node_interact')).toHaveLength(0);
    expect(sent(topic, 'entity_signal')).toHaveLength(0);
    expect((panel.getByLabelText('Сообщение для Резидент') as HTMLInputElement).disabled).toBe(true);
  });

  test('process cards address signals and messages to a concrete recipient', () => {
    const { topic } = setup();
    const panel = render(<NodePanel />);
    fireEvent.click(panel.getByText('Послать сигнал'));
    const input = panel.getByLabelText('Сообщение для Резидент') as HTMLInputElement;
    fireEvent.change(input, { target: { value: '  Проверка связи  ' } });
    fireEvent.submit(input.closest('form')!);
    expect(sent(topic, 'entity_signal')).toEqual([{ ref: contact.ref }]);
    expect(sent(topic, 'entity_message')).toEqual([{ ref: contact.ref, text: 'Проверка связи' }]);
    expect(input.value).toBe('');
  });

  test('draft messages do not leak across node selection and ICE has no message controls', () => {
    const { store } = setup();
    const panel = render(<NodePanel />);
    fireEvent.change(panel.getByLabelText('Сообщение для Резидент'), { target: { value: 'Первому узлу' } });
    act(() => store.dispatch(backendUpdate({ data: { selected: { ...node, address: 'LAN:0002' } } })));
    expect((panel.getByLabelText('Сообщение для Резидент') as HTMLInputElement).value).toBe('');
    act(() => store.dispatch(backendUpdate({ data: { selected: { ...node, contacts: [{
      ...contact, kind: 'ice', can_signal: false, can_message: false, state: 'Патрулирует',
    }] } } })));
    expect(panel.getByText(/ICE · Патрулирует/)).toBeTruthy();
    expect(panel.queryByText('Послать сигнал')).toBeNull();
    expect(panel.queryByLabelText('Сообщение для Резидент')).toBeNull();
  });

  test('entry selection stays accessible across workspaces and is not duplicated in files', () => {
    const { topic } = setup({ workspace_view: 'files', map: null, origin: 'ai', host_actions: [
      { id: 'choose_entry', name: 'Выбрать узел подключения', icon: 'plug' },
    ] });
    const panel = render(<NetrunContent />);
    const header = within(panel.container.querySelector('header')!);
    expect(header.getByText('ИИ')).toBeTruthy();
    const connections = within(panel.getByRole('group', { name: 'Действия подключения' }));
    fireEvent.click(connections.getByText('Выбрать узел подключения'));
    expect(sent(topic, 'choose_entry')).toEqual([{}]);
    expect(panel.getAllByText('Выбрать узел подключения')).toHaveLength(1);
  });
});
