import { act, fireEvent, render } from '@testing-library/react';
import { combineReducers, createStore, setGlobalStore } from 'common/redux';

import { backendReducer, backendUpdate } from '../../backend';
import { debugReducer } from '../../debug';
import { CombatPanel, IncomingAttacks } from './CombatPanel';
import { CombatState, CombatTarget, IncomingProgram } from './types';

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

const setup = (combatOverrides: Partial<CombatState> = {}, locked = 0) => {
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
    data: { combat, locked, breach: null },
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

  test('incoming countdown is shown once in reserved session status, not repeated inside combat', () => {
    const { store, combat } = setup({
      incoming: [{ source: 'ICE-SENTRY', name: 'strike.exe', role: 'attack',
        power: 16, remaining: 2.3, source_ref: enemy.ref }],
      self: { integrity: 74, max_integrity: 100, stunned: false },
    });
    const panel = render(<CombatPanel />);
    expect(panel.queryByText(/ICE-SENTRY готовит strike.exe/)).toBeNull();
    const self = panel.getByText('Вы');
    expect(self).toBeTruthy();
    act(() => store.dispatch(backendUpdate({ data: { combat: {
      ...combat, incoming: [{ ...combat.incoming![0], remaining: 1.2 }],
    } } })));
    panel.rerender(<CombatPanel />);
    expect(panel.queryByText(/ICE-SENTRY готовит strike.exe/)).toBeNull();
    expect(panel.getByText('Вы')).toBeTruthy();
  });

  test('a remote contact shows its actual node and uses the real source ref', () => {
    const { topic } = setup();
    const panel = render(<CombatPanel />);
    expect(panel.getByText('Ответный бой')).toBeTruthy();
    expect(panel.getByText('Сервер LAN:0002')).toBeTruthy();
    fireEvent.click(panel.getByText('strike'));
    expect(uses(topic)).toEqual([{ uid: 'file-strike', target: 'ice-1' }]);
  });

  test('a lawful guard requires deliberate selection before it can be attacked', () => {
    const { topic } = setup({ targets: [{ ...enemy, hostile: false }] });
    const panel = render(<CombatPanel />);
    fireEvent.click(panel.getByText('strike'));
    expect(uses(topic)).toHaveLength(0);
    fireEvent.click(panel.getByText('ICE-SENTRY'));
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
    expect(panel.getByText('Нужна собственная сущность в сети.')).toBeTruthy();
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

  test('shared launch recovery blocks attack and support until the server releases it', () => {
    const { topic, store, combat } = setup({
      action_ready_in: 0.5,
      programs: [strike, { ...strike, uid: 'file-barrier', name: 'barrier.exe', role: 'shield', needs_target: false }],
    });
    const panel = render(<CombatPanel />);
    expect(panel.getByRole('status').textContent).toContain('Общая пауза запуска: ещё 0.5 с.');
    fireEvent.click(panel.getByText('strike'));
    fireEvent.click(panel.getByText('barrier'));
    expect(uses(topic)).toHaveLength(0);

    act(() => store.dispatch(backendUpdate({ data: { combat: { ...combat, action_ready_in: 0 } } })));
    expect(panel.queryByRole('status')).toBeNull();
    fireEvent.click(panel.getByText('strike'));
    expect(uses(topic)).toEqual([{ uid: 'file-strike', target: 'ice-1' }]);
  });

  test('a program keeps its own cooldown after shared recovery expires', () => {
    const { topic, store, combat } = setup({ action_ready_in: 0.1, programs: [{ ...strike, ready_in: 2 }] });
    const panel = render(<CombatPanel />);
    act(() => store.dispatch(backendUpdate({ data: { combat: { ...combat, action_ready_in: 0 } } })));
    expect(panel.getByText('Перезарядка: ещё 2 с.')).toBeTruthy();
    fireEvent.click(panel.getByText('strike'));
    expect(uses(topic)).toHaveLength(0);
  });

  test.each([
    [true, 0, 'Вы оглушены: дождитесь окончания оглушения.'],
    [false, 3, 'Терминал заблокирован: ещё 3 с.'],
  ])('disabled programs explain stun=%s and lock=%s', (stunned, locked, reason) => {
    const { topic } = setup({ self: { integrity: 100, max_integrity: 100, stunned } }, locked);
    const panel = render(<CombatPanel />);
    expect(panel.getByRole('status').textContent).toContain(reason);
    fireEvent.click(panel.getByText('strike'));
    expect(uses(topic)).toHaveLength(0);
  });

  test.each([
    ['attack', 16, '16 урона до щита', 'Включите щит, оглушите ICE или выйдите из узла.'],
    ['stun', 25, '2.5 с оглушения', 'Оглушите ICE или выйдите из узла.'],
    ['trace', 6, '+6% трассировки', 'Прервите взлом или оглушите ICE.'],
  ])('compact warning shows the effect and counterplay for %s', (role, power, effect, advice) => {
    setup({ incoming: [{ source: enemy.name, name: `${role}.exe`, role, power, remaining: 1.2 }] });
    const open = jest.fn();
    const panel = render(<IncomingAttacks compact onCombat={open} />);
    expect(panel.getByRole('alert').textContent).toContain(`${effect} · через 1.2 с`);
    expect(panel.getByText(advice)).toBeTruthy();
    expect(open).not.toHaveBeenCalled();
    if (role === 'stun') {
      expect(panel.getByRole('alert').textContent).not.toContain('щит');
    }
    fireEvent.click(panel.getByText('Открыть бой'));
    expect(open).toHaveBeenCalledTimes(1);
  });

  test('compact warning leads with the soonest impact and retains every threat in its tooltip', () => {
    const incoming: IncomingProgram[] = [
      { source: 'ICE-SENTRY', name: 'trace.exe', role: 'trace', power: 6, remaining: 3 },
      { source: 'ICE-HUNTER', name: 'blackout.exe', role: 'stun', power: 20, remaining: 0.7 },
    ];
    setup({ incoming });
    const panel = render(<IncomingAttacks compact onCombat={() => {}} />);
    const alert = panel.getByRole('alert');
    expect(alert.textContent).toContain('2 с оглушения · через 0.7 с · ICE-HUNTER готовит blackout.exe · угроз: 2');
    expect(alert.textContent).not.toContain('ICE-SENTRY');
    const tooltip = alert.querySelector('[title]')!.getAttribute('title');
    expect(tooltip).toContain('ICE-SENTRY готовит trace.exe · +6% трассировки');
    expect(tooltip).toContain('Щит не защищает от оглушения.');
  });

  test('detailed warnings distinguish damage, stun and trace effects', () => {
    setup({ incoming: [
      { source: enemy.name, name: 'strike.exe', role: 'attack', power: 14, remaining: 2 },
      { source: enemy.name, name: 'blackout.exe', role: 'stun', power: 30, remaining: 1 },
      { source: enemy.name, name: 'trace.exe', role: 'trace', power: 6, remaining: 3 },
    ] });
    const panel = render(<IncomingAttacks onCombat={() => {}} />);
    const alert = panel.getByRole('alert');
    expect(alert.textContent).toContain('strike.exe · 14 урона до щита');
    expect(alert.textContent).toContain('blackout.exe · 3 с оглушения');
    expect(alert.textContent).toContain('trace.exe · +6% трассировки');
    expect(alert.textContent).toContain('Щит не защищает от оглушения.');
    expect(alert.textContent).toContain('Щит не скрывает трассировку.');
  });

  test('a stun-only warning never recommends damage protection', () => {
    setup({ incoming: [{ source: enemy.name, name: 'blackout.exe', role: 'stun', power: 20, remaining: 1 }] });
    const panel = render(<IncomingAttacks onCombat={() => {}} />);
    const alert = panel.getByRole('alert');
    expect(alert.textContent).toContain('Оглушите ICE или выйдите из узла');
    expect(alert.textContent).not.toContain('Щит снижает урон');
  });
});
