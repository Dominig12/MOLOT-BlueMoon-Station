import { fireEvent, render, screen } from '@testing-library/react';
import { combineReducers, createStore, setGlobalStore } from 'common/redux';

import { backendReducer, backendUpdate } from '../backend';
import { debugReducer } from '../debug';
import { NetdmTerminal } from './NetdmTerminal';

const fields = (record: Record<string, string>) => Object.entries(record).map(([name, value]) => ({ name, value }));

const setup = (screenMode: 'tools' | 'home' = 'tools') => {
  const topic = jest.fn();
  (global as any).Byond = { winset: () => {}, winget: () => Promise.resolve(null), topic };
  const store = createStore(combineReducers({ backend: backendReducer, debug: debugReducer }));
  setGlobalStore(store);
  const push = (entries: object[], extra: Record<string, unknown> = {}) => store.dispatch(backendUpdate({
    config: { interface: 'NetdmTerminal' },
    data: { title: 'АПЦ', limit: 1024, scriptLimit: 4096, entries, ...extra },
  }));
  push([]);
  const ui = render(<NetdmTerminal />);
  if (screenMode === 'tools') {
    fireEvent.click(screen.getByText('Инструменты'));
  }
  return {
    push: (entries: object[], extra: Record<string, unknown> = {}) => {
      push(entries, extra); ui.rerender(<NetdmTerminal />);
    },
    commands: () => topic.mock.calls.filter(([message]) => message.type === 'act/run')
      .map(([message]) => JSON.parse(message.payload).line),
    actions: () => topic.mock.calls.map(([message]) => message.type),
  };
};

test('история по стрелкам сохраняет черновик при переходе в справку и обратно', () => {
  const { commands } = setup();
  const getInput = () => screen.getByRole<HTMLInputElement>('textbox', { name: 'Командная строка' });
  fireEvent.change(getInput(), { target: { value: 'services' } });
  fireEvent.keyDown(getInput(), { key: 'Enter' });
  expect(commands()).toEqual(['services']);
  fireEvent.change(getInput(), { target: { value: 'trace 42' } });
  fireEvent.keyDown(getInput(), { key: 'ArrowUp' });
  expect(getInput().value).toBe('services');
  fireEvent.keyDown(getInput(), { key: 'ArrowDown' });
  expect(getInput().value).toBe('trace 42');

  fireEvent.click(screen.getByText('Справка'));
  fireEvent.click(screen.getByText('Устройства'));
  expect(commands()).toEqual(['services', 'help', 'help services']);
  fireEvent.click(screen.getAllByText('Справка')[0]);
  expect(getInput().value).toBe('trace 42');
});

test('результат термометра и доставка запроса используют ID возвращённой операции', () => {
  const { commands, push } = setup();
  push([{
    id: 1, line: 'invoke atmos.alarm.e42 read reason=inspect', status: 'ok', pending: false,
    records: [fields({ instance: 'atmos.alarm.e42', command: 'read', status: 'sent', operation: '987' })],
  }]);
  fireEvent.click(screen.getByLabelText('Проверить доставку'));
  fireEvent.click(screen.getByLabelText('Получить показания'));
  expect(commands()).toEqual(['jobs | where operation -eq "987"', 'result 987']);
});

test('пример из ответа справки подставляется в строку и ждёт запуска игроком', () => {
  const { commands, push } = setup();
  fireEvent.click(screen.getByText('Справка'));
  push([{
    id: 1, line: 'help', status: 'ok', pending: false,
    records: [fields({ topic: 'services', syntax: 'services', description: 'Найти сервисы в сети', example: 'services -type atmos.alarm' })],
  }]);
  expect(screen.getByText('Найти сервисы в сети')).toBeTruthy();
  fireEvent.click(screen.getByText('services -type atmos.alarm'));
  const input = screen.getByRole<HTMLInputElement>('textbox', { name: 'Командная строка' });
  expect(input.value).toBe('services -type atmos.alarm');
  expect(commands()).toEqual(['help']);
});

test('универсальные действия предлагают API и готовят команды без самовольного исполнения', () => {
  const { commands, push } = setup();
  push([{
    id: 1, line: 'services', status: 'ok', pending: false,
    records: [fields({ instance: 'machine.test', type: 'machine.control', hops: '2' })],
  }]);
  fireEvent.click(screen.getByLabelText('Схема сервиса'));
  expect(commands()).toEqual(['api machine.control']);

  const input = screen.getByRole<HTMLInputElement>('textbox', { name: 'Командная строка' });
  fireEvent.click(screen.getByLabelText('Подготовить вызов'));
  expect(input.value).toBe('invoke machine.test ');
  expect(commands()).toEqual(['api machine.control']);

  fireEvent.click(screen.getByLabelText('Подготовить подписку'));
  expect(input.value).toBe('watch machine.test');
  expect(commands()).toEqual(['api machine.control']);
});

test('доставленные события отображаются без сетевого вызова или применения эффекта', () => {
  const { commands, push } = setup();
  push([], {
    watches: ['oxygen'],
    events: [{
      delivery: '802', key: 'oxygen', instance: 'atmos.test', schema: 'atmos.sample',
      payload: '{"pressureKPa":101.3,"quality":"current"}', truncated: false, at: 250,
    }],
  });
  fireEvent.click(screen.getByText('События (1)'));
  expect(screen.getByText('atmos.test · atmos.sample')).toBeTruthy();
  expect(screen.getByText('{"pressureKPa":101.3,"quality":"current"}')).toBeTruthy();
  expect(commands()).toEqual([]);
  fireEvent.click(screen.getByText('oxygen'));
  expect(commands()).toEqual(['unwatch oxygen']);
});


test('IDE validates source through Host without running or starting the program', () => {
  const { actions, push } = setup();
  fireEvent.click(screen.getByText('Редактор'));
  const editor = document.querySelector('textarea') as HTMLTextAreaElement;
  expect(editor).toBeTruthy();
  fireEvent.input(editor, { target: { value: 'self | select node' } });
  fireEvent.click(screen.getByText('Проверить код'));
  expect(actions()).toContain('act/check_script');
  expect(actions()).not.toContain('act/run_script');
  expect(actions()).not.toContain('act/start_program');
  push([{
    id: 1, line: 'check 1', status: 'valid', pending: false, error: null,
    position: null, records: [],
  }]);
  expect(screen.getByText(/Компиляция успешна/)).toBeTruthy();
});


test('обычный игрок видит понятный обзор, а не набор команд и IDE', () => {
  const { actions } = setup('home');
  expect(screen.getByText('Сеть станции')).toBeTruthy();
  expect(screen.getByText('Найти устройства')).toBeTruthy();
  expect(screen.getByText('Тревоги атмосферы')).toBeTruthy();
  expect(screen.queryByRole('textbox', { name: 'Командная строка' })).toBeNull();
  expect(screen.queryByText('Проверить код')).toBeNull();
  // Opening the panel must not make unrequested discovery or control calls.
  expect(actions()).toEqual([]);
});

test('поиск в обзоре использует штатную сеть и показывает понятные сервисы', () => {
  const { commands, push } = setup('home');
  fireEvent.click(screen.getByText('Найти устройства'));
  expect(commands()).toEqual(['services']);
  push([{
    id: 1, line: 'services', status: 'ok', pending: false, error: null,
    records: [fields({ instance: 'atmos.alarm.e42', type: 'atmos.alarm', hops: '2' })],
  }], { connectionReady: true });
  expect(screen.getByText('Атмосферная тревога')).toBeTruthy();
  expect(screen.getByText('atmos.alarm.e42')).toBeTruthy();
  expect(screen.getByText('Подключено')).toBeTruthy();
  // Discovery alone never reads, watches or controls a physical device.
  expect(commands()).toEqual(['services']);
  fireEvent.click(screen.getByText('Показания'));
  fireEvent.click(screen.getByText('Следить'));
  expect(commands()).toEqual([
    'services',
    'invoke atmos.alarm.e42 read reason=inspect',
    'watch atmos.alarm.e42 -key atmos.alarm.e42',
  ]);
});

test('обзор позволяет углубиться в инструменты и вернуться без новых запросов', () => {
  const { commands, actions } = setup('home');
  fireEvent.click(screen.getByText('Тревоги атмосферы'));
  expect(commands()).toEqual(['services -type atmos.alarm']);
  fireEvent.click(screen.getByText('Открыть инструменты'));
  expect(screen.getByRole('textbox', { name: 'Командная строка' })).toBeTruthy();
  fireEvent.click(screen.getByText('Редактор'));
  expect(screen.getByText('Проверить код')).toBeTruthy();
  fireEvent.click(screen.getByText('Обзор'));
  expect(screen.queryByText('Проверить код')).toBeNull();
  expect(commands()).toEqual(['services -type atmos.alarm']);
  expect(actions()).not.toContain('act/start_program');
  expect(actions()).not.toContain('act/run_script');
});

test('карта и входящие события доступны без изучения командной строки', () => {
  const { actions, commands } = setup('home');
  fireEvent.click(screen.getAllByText('Карта сети')[0]);
  expect(actions()).toContain('act/open_space');
  fireEvent.click(screen.getByText('Открыть события'));
  expect(screen.getByText('Доставленные события')).toBeTruthy();
  expect(commands()).toEqual([]);
});


test('простые показания не путают принятие запроса с доставленным ответом', () => {
  const { push, commands } = setup('home');
  const request = {
    id: 1, line: 'invoke atmos.alarm.e42 read reason=inspect', status: 'ok', pending: false, error: null,
    records: [fields({ instance: 'atmos.alarm.e42', command: 'read', status: 'sent', operation: '987' })],
  };
  push([request]);
  expect(screen.getByText(/Запрос принят в сеть/)).toBeTruthy();
  fireEvent.click(screen.getByText('Получить ответ'));
  expect(commands()).toEqual(['result 987']);
  push([request, {
    id: 2, line: 'result 987', status: 'ok', pending: false, error: null,
    records: [fields({ pressureKPa: '101.3', temperatureK: '293', alarm: 'false', danger: '0' })],
  }]);
  expect(screen.getByText(/101.3/)).toBeTruthy();
  expect(screen.getByText(/Тревоги нет/)).toBeTruthy();
});
