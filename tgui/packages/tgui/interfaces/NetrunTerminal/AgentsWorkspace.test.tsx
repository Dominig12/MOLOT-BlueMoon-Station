import { act, fireEvent, render, within } from '@testing-library/react';
import { combineReducers, createStore, setGlobalStore } from 'common/redux';

import { backendReducer, backendUpdate } from '../../backend';
import { AgentsWorkspace } from './AgentsWorkspace';

const template = { uid: 'template-1', name: 'hacker.bot', kind: 'bot', size: 8, agent_profile: 'hacker', preview: 'Взломщик доступных рубежей' };
const builder = { template_uid: template.uid, profile: 'hacker', name: 'Взломщик', description: 'Подбирает доступ', capacity: 64, base_size: 5,
  defaults: [], programs: [], avatars: [{ id: 'cipher', name: 'Шифр' }], accents: [{ id: 'violet', name: 'Ирис', color: '#b7a0ff' }],
  themes: ['ion'], orders: [{ id: 'guard', name: 'На месте' }] };
const setup = () => {
  const topic = jest.fn(); (global as any).Byond = { topic, winset: () => {} };
  const store = createStore(combineReducers({ backend: backendReducer })); setGlobalStore(store);
  store.dispatch(backendUpdate({ data: { workspace_view: 'agents', storage: { files: [template], used: 8, capacity: 128 },
    shard: { name: 'Шард', used: 8, capacity: 128, files: [{ ...template, uid: 'shard-template', name: 'breacher.bot' }] },
    selected: { address: 'TARGET', name: 'Сервер', commands: [] }, entity: { host: 'HOME', host_name: 'Терминал' },
    file: { ...template, source: 'local', content: null, image: null, agent_builder: builder },
    agents: [{ ref: 'agent-1', name: 'ХАК-1', bot_kind: 'hacker', integrity: 90, max_integrity: 90, node: 'HOME', node_name: 'Терминал',
      state: 'ожидает', goal: 'охрана узла', storage: { used: 4, capacity: 64 }, programs: [], files: [], goals: [],
      orders: [{ id: 'hack', name: 'Взломать выбранный узел', needs_node: true }, { id: 'recall', name: 'Отозвать' }] }],
  } }));
  const panel = render(<AgentsWorkspace />);
  const update = (data: object) => act(() => store.dispatch(backendUpdate({ data })));
  const sent = (action: string) => topic.mock.calls.filter(([message]) => message.type === `act/${action}`).map(([message]) => JSON.parse(message.payload));
  return { panel, update, sent };
};

test('agent overview exposes target-aware quick orders, owned templates and an explicit launch', () => {
  const { panel, sent } = setup();
  expect(panel.getByText('Активные агенты (1)')).toBeTruthy();
  expect(panel.getByText('ХАК-1')).toBeTruthy();
  expect(panel.getByText('Цель адресных приказов')).toBeTruthy();
  const card = panel.container.querySelector<HTMLElement>('[data-net-agent="hacker"]');
  expect([...card.querySelectorAll('details')].every((details) => !details.open)).toBe(true);
  fireEvent.click(within(card).getByText('Взломать выбранный узел'));
  expect(sent('agent_order')).toEqual([{ ref: 'agent-1', order: 'hack', address: 'TARGET' }]);
  fireEvent.click(panel.getByText('Запустить агента'));
  expect(sent('bot_launch')).toEqual([{ uid: 'template-1' }]);
  fireEvent.click(panel.getByRole('button', { name: 'Шаблон breacher.bot' }));
  expect(sent('file_select')).toEqual([{ uid: 'shard-template' }]);
  fireEvent.click(panel.getByText('Выбрать на карте'));
  expect(sent('workspace_view')).toEqual([{ page: 'map' }]);
});

test('hidden builders preserve drafts, but an authoritative active deletion clears the selected launch card', () => {
  const { panel, update } = setup();
  fireEvent.click(panel.getByText('Собрать своего агента'));
  fireEvent.change(panel.getByLabelText('Имя агента'), { target: { value: 'Мой черновик' } });
  update({ workspace_view: 'map', file: null, agents: [] });
  expect((panel.getByLabelText('Имя агента') as HTMLInputElement).value).toBe('Мой черновик');
  expect(panel.getByText('ХАК-1')).toBeTruthy();
  update({ workspace_view: 'agents', file: null, agents: [] });
  expect(panel.queryByLabelText('Имя агента')).toBeNull();
  expect(panel.queryByText('Запустить агента')).toBeNull();
  expect(panel.queryByText('ХАК-1')).toBeNull();
});
