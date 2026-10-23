import { fireEvent, render } from '@testing-library/react';
import { combineReducers, createStore, setGlobalStore } from 'common/redux';

import { backendReducer, backendUpdate } from '../../backend';
import { debugReducer } from '../../debug';
import { RemotePanel } from './RemotePanel';
import { MachineWindow } from './types';

type Remote = NonNullable<MachineWindow['remote']>;
const pressure: Remote['actions'][number] = { id: 'pressure', name: 'Установить давление',
  access: 2, allowed: true, params: [{ id: 'pressure', name: 'Давление, кПа', type: 'number', min: 0, max: 100, value: 50 }] };

const setup = (actions: Remote['actions'] = [pressure]) => {
  const topic = jest.fn();
  (global as any).Byond = { topic, winset: () => {} };
  const store = createStore(combineReducers({ backend: backendReducer, debug: debugReducer }));
  setGlobalStore(store);
  store.dispatch(backendUpdate({ config: { interface: 'NetrunTerminal' }, data: {} }));
  const remote: Remote = { interface: 'GasPump', data: { pressure: 50 }, actions };
  return { ...render(<RemotePanel address="PUMP" remote={remote} />), topic, remote };
};
const sent = (topic) => topic.mock.calls.filter((call) => call[0]?.type === 'act/remote_act')
  .map((call) => JSON.parse(call[0].payload));

test('numeric requests reject invalid and out-of-range values before delivery', () => {
  const panel = setup();
  const field = panel.getByLabelText('Давление, кПа');
  for (const value of ['', 'abc', 'Infinity', '1e999', '0x10', '-1', '101']) {
    fireEvent.change(field, { target: { value } });
    fireEvent.click(panel.getByText(pressure.name));
    expect(sent(panel.topic)).toEqual([]);
    expect(panel.getByRole('status')).toBeTruthy();
  }
  fireEvent.change(field, { target: { value: '0' } });
  fireEvent.click(panel.getByText(pressure.name));
  expect(sent(panel.topic)).toEqual([{ address: 'PUMP', request: 'pressure', arguments: { pressure: 0 } }]);
});

test('Russian decimal input sends a number and live polling retains the draft', () => {
  const panel = setup();
  const field = panel.getByLabelText('Давление, кПа') as HTMLInputElement;
  fireEvent.change(field, { target: { value: '42,5' } });
  panel.rerender(<RemotePanel address="PUMP" remote={{ ...panel.remote,
    actions: [{ ...pressure, params: [{ ...pressure.params[0], value: 20 }] }] }} />);
  expect(field.value).toBe('42,5');
  fireEvent.click(panel.getByText(pressure.name));
  expect(sent(panel.topic)).toEqual([{ address: 'PUMP', request: 'pressure', arguments: { pressure: 42.5 } }]);
});

test('provider rejection is visible and disables the actual parameter input', () => {
  const reason = 'Панель заблокирована.';
  const panel = setup([{ ...pressure, allowed: false, reason }]);
  expect(panel.getByRole('status').textContent).toBe(reason);
  expect((panel.getByLabelText('Давление, кПа') as HTMLInputElement).disabled).toBe(true);
  fireEvent.click(panel.getByText(pressure.name));
  expect(sent(panel.topic)).toEqual([]);
});

test('switching to another endpoint does not reuse its previous numeric draft', () => {
  const panel = setup();
  fireEvent.change(panel.getByLabelText('Давление, кПа'), { target: { value: '88' } });
  panel.rerender(<RemotePanel address="OTHER-PUMP" remote={panel.remote} />);
  expect((panel.getByLabelText('Давление, кПа') as HTMLInputElement).value).toBe('50');
});
