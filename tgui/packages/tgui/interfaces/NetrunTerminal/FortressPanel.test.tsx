import { act, fireEvent, render } from '@testing-library/react';
import { combineReducers, createStore, setGlobalStore } from 'common/redux';

import { backendReducer, backendUpdate } from '../../backend';
import { AgentsPanel } from './AgentsPanel';
import { ungroupedCommands } from './CommandList';
import { FortressPanel } from './FortressPanel';
import { FortressDetails, NetCommand } from './types';

const command = (id: string, extra: Partial<NetCommand> = {}): NetCommand => ({ id, name: id, desc: '', icon: 'hammer',
  danger: false, access: 3, allowed: true, illegal: false, trace: 0, group: 'fortress', ...extra });
const fortress: FortressDetails = {
  name: 'Архив РнД', owner: 'Станция', faction: 'station', preset: 'Архив РнД', security_bonus: 2,
  slots_used: 9, slots_max: 12, can_manage: false, manage_reason: 'Нужен демон forge.exe в памяти или на подключённом шарде.',
  modules: [
    { ref: 'm1', kind: 'wall', name: 'Стена', desc: '', integrity: 160, max_integrity: 160, status: 'online' },
    { ref: 'm2', kind: 'turret', name: 'Турель', desc: '', integrity: 0, max_integrity: 90, status: 'destroyed' },
    { ref: 'm3', kind: 'vault', name: 'Хранилище', desc: '', integrity: 30, max_integrity: 110, status: 'building', remaining: 12 },
  ],
};
const setupBackend = (data: object) => {
  const topic = jest.fn();
  (global as any).Byond = { topic, winset: () => {} };
  const store = createStore(combineReducers({ backend: backendReducer }));
  setGlobalStore(store);
  store.dispatch(backendUpdate({ data }));
  return { topic, store };
};

test('fortress requests leave the generic command grid for their own section', () => {
  const commands = [command('scan', { group: null }), command('fort_build@wall'), command('fort_repair')];
  expect(ungroupedCommands(commands).map((entry) => entry.id)).toEqual(['scan']);
});

test('the fortress section shows modules, slots and why the viewer cannot manage it', () => {
  const onCommand = jest.fn();
  const panel = render(<FortressPanel fortress={fortress} access={2} onCommand={onCommand}
    commands={[command('fort_build@wall', { allowed: false, unavailable_reason: 'Нужен ROOT.' }), command('fort_repair')]} />);
  expect(panel.getByText('Архив РнД', { selector: 'div' })).toBeTruthy();
  expect(panel.getByText('Слоты: 9/12')).toBeTruthy();
  expect(panel.getByText('разрушен')).toBeTruthy();
  expect(panel.getByText('строится · 12 с')).toBeTruthy();
  expect(panel.getByText(/Нужен демон forge.exe/)).toBeTruthy();
  fireEvent.click(panel.getByText('fort_repair'));
  expect(onCommand).toHaveBeenCalledWith('fort_repair');
  fireEvent.click(panel.getByText('Построить'));
  expect(panel.getByRole('group', { name: 'Постройка модулей' })).toBeTruthy();
});

test('agents list their state and send orders with the selected node', () => {
  const { topic } = setupBackend({
    selected: { address: 'NODE-7' },
    agents: [{ ref: 'agent-1', name: 'GUARD-01', bot_kind: 'sentinel', node: 'NODE-1', node_name: 'Терминал',
      integrity: 90, max_integrity: 120, state: 'охрана', goal: 'охрана узла Терминал', storage: { used: 8, capacity: 16 },
      orders: [{ id: 'recall', name: 'Отозвать' }, { id: 'guard', name: 'Перевести на выбранный узел', needs_node: true }] }],
  });
  const panel = render(<AgentsPanel />);
  expect(panel.getByText('GUARD-01')).toBeTruthy();
  expect(panel.getByText('Задача: охрана узла Терминал')).toBeTruthy();
  act(() => { fireEvent.click(panel.getByText('Перевести на выбранный узел')); });
  const request = topic.mock.calls.find(([message]) => message.type === 'act/agent_order')[0];
  expect(JSON.parse(request.payload)).toEqual(expect.objectContaining({ ref: 'agent-1', order: 'guard', address: 'NODE-7' }));
});
