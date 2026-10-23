import { act, fireEvent, render, waitFor } from '@testing-library/react';
import { combineReducers, createStore, setGlobalStore } from 'common/redux';

import { backendReducer, backendUpdate } from '../../backend';
import { debugReducer } from '../../debug';
import { StationMap } from './NetworkMap';
import { mountNetrunPixi } from './pixiSurface';
import { makePixiSurfaceMock } from './testSupport/pixiSurfaceMock';
import { NetrunFeedbackProvider } from './useNetrunBackend';

jest.mock('./pixiSurface', () => ({ mountNetrunPixi: jest.fn() }));
const mount = jest.mocked(mountNetrunPixi);
const source = { address: 'SOURCE', name: 'APC', type: 'apc', x: 0, y: 0, online: true,
  security: 1, access: 2, legit: 2, entities: 0, active: false, uplink: null, commands: [], status: [] };
const peer = { ...source, address: 'PEER', name: 'Сервер', type: 'server', x: 20, access: 0, legit: 0 };
const View = () => <NetrunFeedbackProvider><StationMap /></NetrunFeedbackProvider>;

const setup = () => {
  const topic = jest.fn();
  (global as any).Byond = { winset: () => {}, topic };
  const store = createStore(combineReducers({ backend: backendReducer, debug: debugReducer }));
  setGlobalStore(store);
  store.dispatch(backendUpdate({ config: { interface: 'NetrunTerminal' }, data: {
    workspace_view: 'map', origin: 'terminal', uplink: true, wireless: false, locked: 0, trace: 0,
    networks: [], storage: { files: [], used: 0, capacity: 10 }, host_actions: [], windows: [],
    selected: source, selected_network: null, entity: null, jack: null, ping_route: null,
    map: { nodes: [source, peer], edges: [], gateways: [], focus: source.address, revision: 1 },
  } }));
  const panel = render(<View />);
  const update = (data: object) => {
    act(() => store.dispatch(backendUpdate({ data })));
    panel.rerender(<View />);
  };
  const selection = () => topic.mock.calls.filter((call) => call[0]?.type === 'act/select')
    .map((call) => JSON.parse(call[0].payload));
  return { panel, store, update, selection };
};
beforeEach(() => { mount.mockImplementation(async (host) => makePixiSurfaceMock(host)); });

test('keyboard selection gives immediate GPU feedback and only the matching server receipt can reject it', async () => {
  const { panel, store, selection, update } = setup();
  await waitFor(() => expect(panel.getByLabelText('Карта сети').getAttribute('data-net-runtime')).toBe('ready'));
  fireEvent.keyDown(panel.getByLabelText('Карта сети'), { key: 'd' });
  expect(panel.getByText('Выбираем: Сервер…')).toBeTruthy();
  expect(store.getState().backend.data.selected.address).toBe('SOURCE');
  const [request] = selection();
  expect(request.address).toBe('PEER');
  expect(request._netrun_action).toBeTruthy();
  update({ input_ack: 'another-operation' });
  expect(panel.getByText('Выбираем: Сервер…')).toBeTruthy();
  update({ input_ack: request._netrun_action });
  await waitFor(() => expect(panel.getByText('Узел не выбран. Проверьте доступ и связь.')).toBeTruthy());
  const surface = await mount.mock.results[0].value;
  expect(surface.updateActors).toHaveBeenLastCalledWith(expect.anything(),
    expect.objectContaining({ selected: 'SOURCE', selectionPending: false }), expect.any(Array), expect.any(Map));
});

test('a confirmed keyboard choice keeps its selection and never claims a rejection', async () => {
  const { panel, selection, update } = setup();
  await waitFor(() => expect(panel.getByLabelText('Карта сети').getAttribute('data-net-runtime')).toBe('ready'));
  fireEvent.keyDown(panel.getByLabelText('Карта сети'), { key: 'd' });
  const [request] = selection();
  update({ input_ack: request._netrun_action, selected: peer });
  await waitFor(() => expect(panel.getByText('Выбран: Сервер')).toBeTruthy());
  expect(panel.queryByText('Узел не выбран. Проверьте доступ и связь.')).toBeNull();
});
