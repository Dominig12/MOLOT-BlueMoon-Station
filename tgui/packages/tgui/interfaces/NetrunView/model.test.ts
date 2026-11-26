import {
  alertShort,
  alertStroke,
  DEFAULT_LAYERS,
  findHost,
  formatAge,
  formatCooldown,
  HostView,
  labelOf,
  layoutHosts,
  Panel,
  pointAlong,
  shapeOf,
  summarise,
  TABS,
  trafficLatency,
  trafficRows,
  trafficState,
  TrafficView,
  travelMarkers,
  travelProgress,
  VisualView,
  visibleHosts,
  visibleLinks,
} from './model';

const host = (overrides: Partial<HostView> = {}): HostView => ({
  host: 1,
  name: 'deck.1',
  node: 0,
  hostClass: 'Cyberdeck',
  level: 'identified',
  confidence: 100,
  ageMs: 0,
  stale: false,
  available: true,
  bufferCu: 4,
  effects: 0,
  identified: true,
  ...overrides,
});

describe('карта и подписи', () => {
  test('имя показывается только у опознанного хоста', () => {
    expect(labelOf(host())).toBe('deck.1');
    expect(labelOf(host({ identified: false, name: '' }))).toBe('Cyberdeck');
  });

  test('форма узла зависит от класса и переживает монохромный экран', () => {
    expect(shapeOf('AccessPoint')).toBe('square');
    expect(shapeOf('Relay')).toBe('diamond');
    expect(shapeOf('Server')).toBe('hexagon');
    expect(shapeOf('terminal')).toBe('circle');
    expect(shapeOf('неизвестно')).toBe('circle');
  });

  test('раскладка стабильна при добавлении хоста и не сдвигает существующие', () => {
    const first = layoutHosts([host({ host: 1 }), host({ host: 2 })]);
    const grown = layoutHosts([host({ host: 1 }), host({ host: 2 }), host({ host: 3 })]);
    expect(grown[0]).toMatchObject({ x: first[0].x, y: first[0].y });
    expect(grown[1]).toMatchObject({ x: first[1].x, y: first[1].y });
    expect(grown[2].x).not.toBe(first[1].x);
  });

  test('скрытие устаревших убирает только их', () => {
    const fresh = host({ host: 1 });
    const stale = host({ host: 2, stale: true });
    expect(visibleHosts([fresh, stale], false)).toHaveLength(2);
    expect(visibleHosts([fresh, stale], true)).toEqual([fresh]);
  });

  test('ребро, ведущее к скрытому хосту, не показывается', () => {
    const shown = [host({ host: 1 })];
    const links = [
      { a: 1, b: 2, cost: 1 },
      { a: 1, b: 3, cost: 1 },
    ];
    expect(visibleLinks(links, shown)).toEqual([]);
    expect(visibleLinks(links, [host({ host: 1 }), host({ host: 2 })])).toEqual([{ a: 1, b: 2, cost: 1 }]);
  });
});

describe('слои карты', () => {
  const visual = (overrides: Partial<VisualView> = {}): VisualView => ({
    kind: 'presence',
    own: false,
    host: 1,
    destination: 2,
    state: 'traveling',
    hops: 1,
    startedAt: 0,
    arriveAt: 1000,
    ...overrides,
  });

  test('прогресс перехода зажат в свои границы и не зацикливается', () => {
    expect(travelProgress(0, 1000, 0)).toBe(0);
    expect(travelProgress(0, 1000, 500)).toBe(0.5);
    expect(travelProgress(0, 1000, 5_000)).toBe(1);
    expect(travelProgress(0, 1000, -10)).toBe(0);
    expect(travelProgress(0, 0, 999)).toBe(1);
  });

  test('маркер перехода показывает реальную долю пути', () => {
    const hosts = [host({ host: 1 }), host({ host: 2 })];
    expect(travelMarkers({ hosts, visuals: [visual()], now: 250 }, DEFAULT_LAYERS)).toEqual([
      { from: 1, to: 2, own: false, travelling: true, progress: 0.25 },
    ]);
  });

  test('переход к нераскрытому хосту не рисуется: ребро не выдаёт скрытый узел', () => {
    const hosts = [host({ host: 1 })];
    expect(travelMarkers({ hosts, visuals: [visual()], now: 0 })).toEqual([]);
  });

  test('своё стоящее присутствие видно, чужое стоящее — нет', () => {
    const hosts = [host({ host: 1 }), host({ host: 2 })];
    expect(travelMarkers({ hosts, visuals: [visual({ state: 'idle' })], now: 0 })).toEqual([]);
    const own = travelMarkers({ hosts, visuals: [visual({ state: 'idle', own: true })], now: 0 });
    expect(own).toHaveLength(1);
    expect(own[0]).toMatchObject({ from: 1, to: 1, own: true, travelling: false });
  });

  test('скрытие устаревших убирает и маркеры к ним', () => {
    const fresh = host({ host: 1 });
    const stale = host({ host: 2, stale: true });
    const layers = { ...DEFAULT_LAYERS, freshOnly: true };
    expect(travelMarkers({ hosts: [fresh, stale], visuals: [visual()], now: 250 }, layers)).toEqual([]);
  });

  test('кольцо и подпись описывают один и тот же уровень тревоги', () => {
    expect(alertStroke(undefined)).toBeNull();
    expect(alertStroke('Normal')).toBeNull();
    expect(alertStroke('Lockdown')).not.toBeNull();
    expect(alertShort('Alert')).toBe('тревога');
    expect(alertShort(undefined)).toBe('');
  });

  test('точка на ребре интерполируется и не выходит за концы', () => {
    expect(pointAlong({ x: 0, y: 0 }, { x: 10, y: 20 }, 0.5)).toEqual({ x: 5, y: 10 });
    expect(pointAlong({ x: 0, y: 0 }, { x: 10, y: 20 }, 5)).toEqual({ x: 10, y: 20 });
    expect(pointAlong({ x: 0, y: 0 }, { x: 10, y: 20 }, -1)).toEqual({ x: 0, y: 0 });
  });
});

describe('форматирование', () => {
  test('возраст данных читается человеком', () => {
    expect(formatAge(0)).toBe('0 с');
    expect(formatAge(59_000)).toBe('59 с');
    expect(formatAge(61_000)).toBe('1 мин');
  });

  test('перезарядка без значения показывается прочерком', () => {
    expect(formatCooldown(0)).toBe('—');
    expect(formatCooldown(1500)).toBe('1.5 с');
  });

  test('итоги нижней строки считаются из проекции', () => {
    const panel = {
      knowledge: { known: 3, stale: 1, total: 4 },
      actions: [{ id: 'a' }, { id: 'b' }],
      operations: [{ operation: 1 }],
    } as unknown as Panel;
    expect(summarise(panel)).toEqual({ hosts: '3', stale: '1', actions: '2', operations: '1' });
    expect(summarise(null)).toEqual({ hosts: '—', stale: '—', actions: '—', operations: '—' });
  });

  test('поиск выбранного хоста не падает на пустых данных', () => {
    expect(findHost(null, 1)).toBeNull();
    expect(findHost({ hosts: [host()] } as Panel, null)).toBeNull();
    expect(findHost({ hosts: [host()] } as Panel, 1)?.host).toBe(1);
    expect(findHost({ hosts: [host()] } as Panel, 99)).toBeNull();
  });
});

describe('вкладки', () => {
  test('навигация повторяет целевой набор и не содержит пустых разделов', () => {
    expect(TABS.map(tab => tab.key)).toEqual([
      'network',
      'traffic',
      'hosts',
      'programs',
      'life',
      'agents',
      'events',
    ]);
    expect(TABS.every(tab => tab.label.length > 0)).toBe(true);
  });
});

describe('трафик', () => {
  const entry = (overrides: Partial<TrafficView> = {}): TrafficView => ({
    operation: 1,
    kind: 'command',
    category: 'security',
    status: 'committed',
    from: 1,
    to: 2,
    at: 1_000,
    doneAt: 1_400,
    reason: null,
    ...overrides,
  });

  test('незавершённый запрос не выдаётся за успешный', () => {
    expect(trafficState(entry({ doneAt: 0 }))).toBe('in_flight');
    expect(trafficLatency(entry({ doneAt: 0 }))).toBeNull();
    expect(trafficState(entry())).toBe('done');
    expect(trafficLatency(entry())).toBe(400);
  });

  test('время запроса не считается отрицательным', () => {
    expect(trafficLatency(entry({ at: 2_000, doneAt: 1_500 }))).toBeNull();
  });

  test('строки идут от нового к старому', () => {
    const rows = trafficRows([entry({ operation: 1 }), entry({ operation: 5 }), entry({ operation: 3 })]);
    expect(rows.map(row => row.operation)).toEqual([5, 3, 1]);
  });

  test('пустая проекция не падает', () => {
    expect(trafficRows(undefined)).toEqual([]);
    expect(trafficRows([])).toEqual([]);
  });
});
