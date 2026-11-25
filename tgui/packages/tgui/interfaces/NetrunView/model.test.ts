import {
  findHost,
  formatAge,
  formatCooldown,
  HostView,
  labelOf,
  layoutHosts,
  Panel,
  shapeOf,
  summarise,
  TABS,
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
    expect(TABS.map(tab => tab.key)).toEqual(['network', 'hosts', 'programs', 'events']);
    expect(TABS.every(tab => tab.label.length > 0)).toBe(true);
  });
});
