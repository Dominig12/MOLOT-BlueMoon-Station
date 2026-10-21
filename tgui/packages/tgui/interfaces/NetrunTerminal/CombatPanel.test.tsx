import { act, fireEvent, render } from '@testing-library/react';
import { combineReducers, createStore, setGlobalStore } from 'common/redux';

import { backendReducer, backendUpdate } from '../../backend';
import { debugReducer } from '../../debug';
import { CombatPanel, IncomingAttacks } from './CombatPanel';
import { CombatState, CombatTarget } from './types';

const enemy: CombatTarget = {
  ref: 'ice-1', name: 'ICE-SENTRY', kind: 'ice', hostile: true,
  integrity: 120, max_integrity: 120, stunned: false,
  node: 'LAN:0002', node_name: 'Сервер', unavailable_reason: null,
};

const strike = {
  id: 'strike', uid: 'file-strike', name: 'strike.exe', desc: 'Удар по процессу',
  size: 2, role: 'attack', power: 18, cooldown: 2, consumable: false,
  needs_target: true, icon: 'bolt', ready_in: 0,
};

const setup = (combatOverrides: Partial<CombatState> = {}) => {
  const topic = jest.fn();
  (global as any).Byond = { winset: () => {}, topic };
  const store = createStore(combineReducers({ backend: backendReducer, debug: debugReducer }));
  setGlobalStore(store);
  const combat: CombatState = {
    node: null, node_name: null, self: null,
    targets: [enemy], programs: [strike], incoming: [],
    ...combatOverrides,
  };
  store.dispatch(backendUpdate({
    config: { interface: 'NetrunTerminal' },
    data: { combat, locked: 0, breach: null },
  }));
  return { topic, store, combat };
};

const uses = (topic) => topic.mock.calls
  .filter((call) => call[0]?.type === 'act/program_use')
  .map((call) => JSON.parse(call[0].payload));

describe('Netrun combat contacts', () => {
  let actionTime = Date.now();
  beforeEach(() => {
    actionTime += 1000;
    jest.spyOn(Date, 'now').mockReturnValue(actionTime);
  });
  afterEach(() => jest.restoreAllMocks());

  test('a remote contact shows its actual node and uses the real source ref', () => {
    const { topic } = setup();
    const panel = render(<CombatPanel />);
    expect(panel.getByText('Ответный бой')).toBeTruthy();
    expect(panel.getByText('Сервер LAN:0002')).toBeTruthy();
    fireEvent.click(panel.getByText('strike'));
    expect(uses(topic)).toEqual([{ uid: 'file-strike', target: 'ice-1' }]);
  });

  test('retains an opponent when its announced program enters cooldown', () => {
    const { topic, store, combat } = setup({
      incoming: [{ source: enemy.name, source_ref: enemy.ref, name: 'trace.exe', role: 'trace', power: 6, remaining: 3 }],
    });
    const panel = render(<CombatPanel />);
    act(() => store.dispatch(backendUpdate({ data: { combat: { ...combat, incoming: [],
      targets: [{ ...enemy, programs: [{ name: 'trace.exe', desc: '', role: 'trace', power: 6, cooldown: 5, windup: 3, ready_in: 5 }] }],
    } } })));
    panel.rerender(<CombatPanel />);
    expect(panel.getByText('ICE-SENTRY')).toBeTruthy();
    expect(panel.getByText('trace.exe: перезарядка 5 с')).toBeTruthy();
    fireEvent.click(panel.getByText('strike'));
    expect(uses(topic)).toEqual([{ uid: 'file-strike', target: 'ice-1' }]);
  });

  test('replaces removed selection with the next usable hostile source', () => {
    const { topic, store, combat } = setup();
    const panel = render(<CombatPanel />);
    act(() => store.dispatch(backendUpdate({ data: { combat: { ...combat,
      targets: [{ ...enemy, ref: 'ice-2', name: 'ICE-HUNTER' }],
    } } })));
    panel.rerender(<CombatPanel />);
    fireEvent.click(panel.getByText('strike'));
    expect(uses(topic)).toEqual([{ uid: 'file-strike', target: 'ice-2' }]);
  });

  test('route loss disables a reply and restoration reselects the same opponent', () => {
    const { topic, store, combat } = setup();
    const panel = render(<CombatPanel />);
    act(() => store.dispatch(backendUpdate({ data: { combat: { ...combat,
      targets: [{ ...enemy, unavailable_reason: 'Нет маршрута к противнику.' }],
    } } })));
    panel.rerender(<CombatPanel />);
    expect(panel.getByText('Нет маршрута к противнику.')).toBeTruthy();
    fireEvent.click(panel.getByText('strike'));
    expect(uses(topic)).toHaveLength(0);
    act(() => store.dispatch(backendUpdate({ data: { combat } })));
    panel.rerender(<CombatPanel />);
    fireEvent.click(panel.getByText('strike'));
    expect(uses(topic)).toEqual([{ uid: 'file-strike', target: 'ice-1' }]);
  });

  test('a remote console cannot use entity-only support programs', () => {
    const { topic } = setup({ programs: [{ ...strike, uid: 'file-barrier', name: 'barrier.exe',
      role: 'shield', needs_target: false, unavailable_reason: 'Нужна собственная сущность в сети.',
    }] });
    const panel = render(<CombatPanel />);
    fireEvent.click(panel.getByText('barrier'));
    expect(uses(topic)).toHaveLength(0);
  });

  test('a finished contact removes the selected ref and blocks further use', () => {
    const { topic, store, combat } = setup();
    const panel = render(<CombatPanel />);
    act(() => store.dispatch(backendUpdate({ data: { combat: { ...combat, targets: [] } } })));
    panel.rerender(<CombatPanel />);
    fireEvent.click(panel.getByText('strike'));
    expect(uses(topic)).toHaveLength(0);
    expect(panel.queryByText('ICE-SENTRY')).toBeNull();
  });

  test('trace warnings preserve their source identity while the puzzle is open', () => {
    setup({ incoming: [{ source: enemy.name, source_ref: enemy.ref, source_node: enemy.node,
      name: 'trace.exe', role: 'trace', power: 6, remaining: 3 }] });
    const open = jest.fn();
    const panel = render(<IncomingAttacks onCombat={open} />);
    expect(panel.getByRole('alert').textContent).toContain('ICE-SENTRY готовит trace.exe');
    fireEvent.click(panel.getByText('Открыть бой'));
    expect(open).toHaveBeenCalledTimes(1);
  });
});
