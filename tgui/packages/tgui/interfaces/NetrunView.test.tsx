import { fireEvent, render, screen } from '@testing-library/react';

import { NetrunWindow } from './NetrunView';
import { Data } from './NetrunView/model';

const panel = (overrides: Partial<Data['panel']> = {}) => ({
  now: 1000,
  ticks: 10,
  principal: 7,
  hosts: [
    {
      host: 1,
      name: 'deck.1',
      node: 5,
      hostClass: 'Cyberdeck',
      level: 'identified',
      confidence: 100,
      ageMs: 2_000,
      stale: false,
      available: true,
      bufferCu: 12.5,
      effects: 0,
      identified: true,
    },
    {
      host: 2,
      name: '',
      node: 6,
      hostClass: 'Relay',
      level: 'observed',
      confidence: 80,
      ageMs: 75_000,
      stale: true,
      available: true,
      bufferCu: 3,
      effects: 1,
      identified: false,
    },
  ],
  links: [{ a: 1, b: 2, cost: 1 }],
  actions: [
    {
      id: 'net.inspect',
      kind: 'query',
      category: 'perception',
      capability: 'read',
      computeCost: 1,
      memoryCost: 0,
      cooldownMs: 0,
      rangeHops: 8,
      displayName: 'Осмотр',
      documentation: 'Читает состояние известного хоста.',
    },
  ],
  operations: [
    { operation: 3, status: 'committed', kind: 'query', category: 'perception', reason: null, result: null },
  ],
  programs: [
    {
      process: 4,
      definition: 'guardian',
      state: 'waiting',
      instructions: 12,
      runs: 1,
      fault: null,
      lastAction: 'net.inspect',
      lastOutcome: 'committed',
    },
  ],
  presets: [
    {
      name: 'Inspector',
      text: 'program "Inspector"\n  invoke net.inspect self\n  stop',
    },
  ],
  knowledge: { known: 2, stale: 1, total: 2 },
  presence: null,
  lives: [],
  backups: [],
  agents: [],
  presences: [],
  ...overrides,
});

it('offers travel from the selected host and reports where the presence stands', () => {
  const act = jest.fn();
  render(<NetrunWindow data={{ panel: panel(), error: null, notice: null }} act={act} />);
  fireEvent.click(screen.getAllByText('deck.1')[0]);
  const enter = screen.getByText('Войти');
  expect(screen.getByText('Присутствие не активно')).toBeTruthy();
  fireEvent.click(enter);
  expect(act).toHaveBeenCalledWith('travel', { mode: 'enter', target: 1 });
});

it('shows the move and its abort once a presence exists elsewhere', () => {
  const act = jest.fn();
  const presence = { identity: 9, host: 2, state: 'idle', destination: 0, hops: 0, arriveAt: 0 };
  render(<NetrunWindow data={{ panel: panel({ presence, presences: [presence] }), error: null, notice: null }} act={act} />);
  fireEvent.click(screen.getAllByText('deck.1')[0]);
  expect(screen.getByText('Стою на хосте 2')).toBeTruthy();
  fireEvent.click(screen.getByText('Идти сюда'));
  expect(act).toHaveBeenCalledWith('travel', { mode: 'move', target: 1 });
});

it('offers an abort while the presence is in transit', () => {
  const act = jest.fn();
  const presence = { identity: 9, host: 2, state: 'traveling', destination: 1, hops: 3, arriveAt: 4000 };
  render(<NetrunWindow data={{ panel: panel({ presence, presences: [presence] }), error: null, notice: null }} act={act} />);
  fireEvent.click(screen.getAllByText('deck.1')[0]);
  expect(screen.getByText('В пути: 3 переходов')).toBeTruthy();
  fireEvent.click(screen.getByText('Прервать переход'));
  expect(act).toHaveBeenCalledWith('travel', { mode: 'abort' });
});

it('shows the core, its integrity and the three operations it supports', () => {
  const act = jest.fn();
  const core = { identity: 9, host: 2, state: 'degraded', integrity: 40, control: 3, migrating: false, destination: 0 };
  render(<NetrunWindow data={{ panel: panel({ lives: [core] }), error: null, notice: null }} act={act} />);
  fireEvent.click(screen.getAllByText('deck.1')[0]);
  fireEvent.click(screen.getByText('Ядро'));
  expect(screen.getByText('degraded')).toBeTruthy();
  fireEvent.click(screen.getByText('Копия на выбранном хосте'));
  expect(act).toHaveBeenCalledWith('life', { action: 'backup', target: 1 });
  fireEvent.click(screen.getByText('Перенести ядро'));
  expect(act).toHaveBeenCalledWith('life', { action: 'migrate', target: 1 });
});

it('offers to create a core when the observer has none', () => {
  const act = jest.fn();
  render(<NetrunWindow data={{ panel: panel(), error: null, notice: null }} act={act} />);
  fireEvent.click(screen.getAllByText('deck.1')[0]);
  fireEvent.click(screen.getByText('Ядро'));
  expect(screen.getByText(/нет цифрового ядра/)).toBeTruthy();
  fireEvent.click(screen.getByText('Создать ядро на выбранном хосте'));
  expect(act).toHaveBeenCalledWith('life', { action: 'create', target: 1 });
});

it('lists the stored copies of the core and restores one of them', () => {
  const act = jest.fn();
  const core = { identity: 9, host: 2, state: 'degraded', integrity: 40, control: 3, migrating: false, destination: 0 };
  const backups = [{ id: 7, host: 2, integrity: 80, control: 2, takenAt: 1_000 }];
  render(<NetrunWindow data={{ panel: panel({ lives: [core], backups }), error: null, notice: null }} act={act} />);
  fireEvent.click(screen.getAllByText('deck.1')[0]);
  fireEvent.click(screen.getByText('Ядро'));
  expect(screen.getByText('Копии')).toBeTruthy();
  fireEvent.click(screen.getByText('Восстановить'));
  expect(act).toHaveBeenCalledWith('life', { action: 'restore_backup', backup: 7, target: 1 });
});

it('shows the strains and plants a virus or ICE on the selected host', () => {
  const act = jest.fn();
  const agent = { id: 5, strain: 'window.virus', kind: 'virus', host: 2, generation: 2, integrity: 90, spreads: 1 };
  render(<NetrunWindow data={{ panel: panel({ agents: [agent] }), error: null, notice: null }} act={act} />);
  fireEvent.click(screen.getAllByText('deck.1')[0]);
  fireEvent.click(screen.getByText('Агенты'));
  expect(screen.getByText('window.virus')).toBeTruthy();
  fireEvent.click(screen.getByText('Вирус'));
  expect(act).toHaveBeenCalledWith('agents', { action: 'deploy', target: 1, kind: 'virus' });
  fireEvent.click(screen.getByText('ICE'));
  expect(act).toHaveBeenCalledWith('agents', { action: 'deploy', target: 1, kind: 'ice' });
});

it('cleans one strain and explains an empty list instead of showing nothing', () => {
  const act = jest.fn();
  render(<NetrunWindow data={{ panel: panel({ agents: [] }), error: null, notice: null }} act={act} />);
  fireEvent.click(screen.getAllByText('deck.1')[0]);
  fireEvent.click(screen.getByText('Агенты'));
  expect(screen.getByText(/Ваших штаммов в сети нет/)).toBeTruthy();
});

const renderWindow = (data: Data) => {
  const act = jest.fn();
  const ui = render(<NetrunWindow data={data} act={act} />);
  return { act, ...ui };
};

test('карта открывается первой и показывает опознанного хост по имени, а неопознанного по классу', () => {
  renderWindow({ panel: panel() as Data['panel'], error: null, notice: null });
  expect(screen.getByLabelText('Карта сети')).toBeTruthy();
  expect(screen.getByText('deck.1')).toBeTruthy();
  expect(screen.getByText(/Relay/)).toBeTruthy();
  expect(screen.getByText(/устаревших: 1/)).toBeTruthy();
});

test('вкладка «Хосты» перечисляет данные и отмечает устаревшие', () => {
  renderWindow({ panel: panel() as Data['panel'], error: null, notice: null });
  fireEvent.click(screen.getByText('Хосты'));
  expect(screen.getByText('Cyberdeck')).toBeTruthy();
  expect(screen.getByText('1 мин')).toBeTruthy();
});

test('вкладка «Программы» не даёт запустить действие без выбранного хоста', () => {
  const { act } = renderWindow({ panel: panel() as Data['panel'], error: null, notice: null });
  fireEvent.click(screen.getByText('Программы'));
  // A disabled TGUI button is a plain element, so the behaviour is what is checked: nothing is sent.
  fireEvent.click(screen.getByText('Выполнить'));
  expect(act).not.toHaveBeenCalled();
});

test('выбор хоста на карте открывает контекст и разрешает действие', () => {
  const { act } = renderWindow({ panel: panel() as Data['panel'], error: null, notice: null });
  fireEvent.click(screen.getByLabelText('Хост deck.1'));
  expect(screen.getByText('Выбранный хост')).toBeTruthy();
  fireEvent.click(screen.getByText('Программы'));
  fireEvent.click(screen.getByText('Выполнить'));
  expect(act).toHaveBeenCalledWith('execute', { action: 'net.inspect', target: 1 });
});

test('вкладка «Программы» показывает запущенную программу и её состояние', () => {
  renderWindow({ panel: panel() as Data['panel'], error: null, notice: null });
  fireEvent.click(screen.getByText('Программы'));
  expect(screen.getByText(/guardian/)).toBeTruthy();
  expect(screen.getByText('ожидание')).toBeTruthy();
});

test('библиотека программ показывает текст выбранного пресета и не выдаёт его за права', () => {
  renderWindow({ panel: panel() as Data['panel'], error: null, notice: null });
  fireEvent.click(screen.getByText('Программы'));
  expect(screen.getByText(/чужие права/)).toBeTruthy();
  fireEvent.click(screen.getByText('Inspector'));
  expect(screen.getByText(/invoke net.inspect self/)).toBeTruthy();
});

test('редактор отправляет текст программы на сервер, а не выполняет его сам', () => {
  const { act } = renderWindow({ panel: panel() as Data['panel'], error: null, notice: null });
  fireEvent.click(screen.getByText('Программы'));
  const editor = screen.getByRole<HTMLTextAreaElement>('textbox');
  fireEvent.change(editor, { target: { value: 'program "Probe"\ninvoke net.inspect self\nstop' } });
  fireEvent.click(screen.getByText('Запустить'));
  expect(act).toHaveBeenCalledWith('import', {
    source: 'program "Probe"\ninvoke net.inspect self\nstop',
    target: null,
  });
});

test('пресет открывается в редакторе и запускается оттуда же', () => {
  const { act } = renderWindow({ panel: panel() as Data['panel'], error: null, notice: null });
  fireEvent.click(screen.getByText('Программы'));
  fireEvent.click(screen.getByText('Inspector'));
  fireEvent.click(screen.getByText('Открыть в редакторе'));
  fireEvent.click(screen.getByText('Запустить'));
  const calls = act.mock.calls.filter(([name]) => name === 'import');
  expect(calls.length).toBe(1);
  expect(String(calls[0][1].source)).toContain('invoke net.inspect self');
});

test('вкладка «События» показывает итог операции', () => {
  renderWindow({ panel: panel() as Data['panel'], error: null, notice: null });
  fireEvent.click(screen.getByText('События'));
  expect(screen.getByText('выполнено')).toBeTruthy();
  expect(screen.getByText('#3')).toBeTruthy();
});

test('без данных окно честно сообщает об этом, а не рисует пустую карту', () => {
  renderWindow({ panel: null, error: null, notice: null });
  expect(screen.getByText(/Нет данных/)).toBeTruthy();
});

test('ошибка сервера показывается вместо карты', () => {
  renderWindow({ panel: null, error: 'Сеть недоступна', notice: null });
  expect(screen.getByText('Сеть недоступна')).toBeTruthy();
});
