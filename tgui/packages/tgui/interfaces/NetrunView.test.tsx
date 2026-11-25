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
  knowledge: { known: 2, stale: 1, total: 2 },
  ...overrides,
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
