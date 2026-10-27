import { fireEvent, render, within } from '@testing-library/react';
import { combineReducers, createStore, setGlobalStore } from 'common/redux';

import { backendReducer, backendUpdate } from '../../backend';
import { debugReducer } from '../../debug';
import { MatrixPanel } from './Matrix';
import { MatrixState } from './types';

const setup = () => {
  const topic = jest.fn();
  (global as any).Byond = { winset: () => {}, topic };
  // MatrixPanel gets the puzzle from its parent; actions use the same backend as every workspace.
  const store = createStore(combineReducers({ backend: backendReducer, debug: debugReducer }));
  setGlobalStore(store);
  store.dispatch(backendUpdate({ config: { interface: 'NetrunTerminal' }, data: {} }));
  return topic;
};

const picks = (topic) => topic.mock.calls.filter((call) => call[0]?.type === 'act/breach_pick')
  .map((call) => JSON.parse(call[0].payload));

const memory: MatrixState = {
  minigame: 'memory', target: 'Защищённый узел', security: 3, size: 2,
  cells: [
    { code: '7A', active: false, order: 1 }, { code: 'BD', active: false },
    { code: '55', active: false, order: 2 }, { code: 'E9', active: false },
  ],
  daemons: [], time_left: 25, progress: 0, total: 2, phase: 'reveal', reveal_left: 4,
  mistakes: 0, mistakes_left: 3,
};

describe('Additional Netrun breach games', () => {
  let actionTime = Date.now();
  beforeEach(() => {
    actionTime += 1000;
    jest.spyOn(Date, 'now').mockReturnValue(actionTime);
  });
  afterEach(() => jest.restoreAllMocks());

  test('memory preview cannot send picks and recall removes order hints', () => {
    const topic = setup();
    const panel = render(<MatrixPanel state={memory} />);
    const grid = panel.getByRole('table', { name: 'Эхо памяти' });
    expect(within(grid).getByText('1')).toBeTruthy();
    expect(within(grid).queryByRole('button')).toBeNull();
    fireEvent.click(within(grid).getByText('7A'));
    expect(picks(topic)).toHaveLength(0);
    panel.rerender(<MatrixPanel state={{ ...memory, phase: 'recall', reveal_left: 0,
      cells: memory.cells.map(({ order: _order, ...cell }) => ({ ...cell, active: true })),
    }} />);
    expect(within(grid).queryByText('1')).toBeNull();
    expect(within(grid).getAllByRole('button')).toHaveLength(4);
    fireEvent.keyDown(within(grid).getByRole('button', { name: 'Выбрать ячейку 3, код 55' }), { key: 'Enter' });
    expect(picks(topic)).toEqual([{ index: 3 }]);
  });

  test('a memory retry restores the preview and reports the remaining mistakes', () => {
    setup();
    const panel = render(<MatrixPanel state={{ ...memory, mistakes: 1, mistakes_left: 2, reveal_left: 2 }} />);
    expect(panel.getByText(/Осталось ошибок: 2/)).toBeTruthy();
    expect(panel.getByText(/просмотр ещё 2 с/)).toBeTruthy();
    expect(within(panel.getByRole('table')).queryByRole('button')).toBeNull();
  });

  test('routing sends only available neighboring cells and identifies its objectives', () => {
    const topic = setup();
    const state: MatrixState = {
      minigame: 'routing', target: 'APC', security: 3, size: 2, time_left: 25,
      daemons: [], progress: 1, total: 3,
      cells: [
        { code: null, active: false, entry: true, current: true },
        { code: null, active: false, wall: true },
        { code: null, active: true, checkpoint: true },
        { code: null, active: false, exit: true },
      ],
    };
    const panel = render(<MatrixPanel state={state} />);
    const grid = panel.getByRole('table', { name: 'Маршрутизация пакета' });
    expect(within(grid).getByText('ВХОД')).toBeTruthy();
    expect(within(grid).getByText('ROOT')).toBeTruthy();
    expect(within(grid).getAllByRole('button')).toHaveLength(1);
    fireEvent.click(within(grid).getByText('■'));
    expect(picks(topic)).toHaveLength(0);
    fireEvent.click(within(grid).getByRole('button', { name: 'Выбрать ячейку 3, проход, USER' }));
    expect(picks(topic)).toEqual([{ index: 3 }]);
  });

  test('the first critical access stage explains its cap instead of promising ROOT', () => {
    setup();
    const panel = render(<MatrixPanel state={{ ...memory, access_cap: 2 }} />);
    expect(panel.getByText('Первый контур: USER. Для ROOT выполните отдельный взлом после получения USER.')).toBeTruthy();
  });
});
