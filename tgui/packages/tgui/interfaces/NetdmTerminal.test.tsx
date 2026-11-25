import { fireEvent, render, screen } from '@testing-library/react';

import { NetdmTerminalContent, NetdmTerminalData, NetdmTerminalEvents } from './NetdmTerminal';

const fields = (record: Record<string, string>) => Object.entries(record).map(([name, value]) => ({ name, value }));

type Entry = NetdmTerminalData['entries'][number];
type EntryFixture = Pick<Entry, 'id' | 'line' | 'records'> & Partial<Entry>;

const terminalData = (entries: EntryFixture[] = []): NetdmTerminalData => ({
  title: 'АПЦ',
  limit: 1024,
  scriptLimit: 4096,
  entries: entries.map(entry => ({ pending: false, status: 'ok', error: null, position: null, fuel: null, ...entry })),
  programsEnabled: false,
  kept: null,
  disk: null,
  diskNotice: null,
  loadedScript: null,
});

const setup = () => {
  const act = jest.fn();
  const ui = render(<NetdmTerminalContent data={terminalData()} act={act} />);
  return {
    push: (entries: EntryFixture[]) => ui.rerender(<NetdmTerminalContent data={terminalData(entries)} act={act} />),
    commands: () => act.mock.calls.filter(([action]) => action === 'run').map(([, params]) => params.line),
    actions: () => act.mock.calls.map(([action]) => action),
  };
};

const commandInput = () => screen.getByRole<HTMLInputElement>('textbox', { name: 'Командная строка' });

test('история по стрелкам сохраняет черновик при переходе в справку и обратно', () => {
  const { commands } = setup();
  fireEvent.change(commandInput(), { target: { value: 'services' } });
  fireEvent.keyDown(commandInput(), { key: 'Enter' });
  expect(commands()).toEqual(['services']);
  fireEvent.change(commandInput(), { target: { value: 'trace 42' } });
  fireEvent.keyDown(commandInput(), { key: 'ArrowUp' });
  expect(commandInput().value).toBe('services');
  fireEvent.keyDown(commandInput(), { key: 'ArrowDown' });
  expect(commandInput().value).toBe('trace 42');

  fireEvent.click(screen.getByRole('button', { name: 'Справка' }));
  fireEvent.click(screen.getByText('Устройства'));
  expect(commands()).toEqual(['services', 'help', 'help services']);
  fireEvent.click(screen.getByRole('button', { name: 'Терминал' }));
  expect(commandInput().value).toBe('trace 42');
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
  fireEvent.click(screen.getByRole('button', { name: 'Справка' }));
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
  const onCommand = jest.fn();
  const data = {
    watches: ['oxygen'],
    events: [{
      delivery: '802', key: 'oxygen', instance: 'atmos.test', schema: 'atmos.sample',
      payload: '{"pressureKPa":101.3,"quality":"current"}', truncated: false, at: 250,
    }],
  };
  render(<NetdmTerminalEvents data={data} onCommand={onCommand} />);
  expect(screen.getByText('atmos.test · atmos.sample')).toBeTruthy();
  expect(screen.getByText('{"pressureKPa":101.3,"quality":"current"}')).toBeTruthy();
  expect(onCommand).not.toHaveBeenCalled();
  fireEvent.click(screen.getByText('oxygen'));
  expect(onCommand).toHaveBeenCalledTimes(1);
  expect(onCommand).toHaveBeenCalledWith('unwatch oxygen');
});


test('IDE validates source through Host without running or starting the program', () => {
  const { actions, push } = setup();
  fireEvent.click(screen.getByRole('button', { name: 'Редактор' }));
  const editor = document.querySelector('textarea') as HTMLTextAreaElement;
  expect(editor).toBeTruthy();
  fireEvent.input(editor, { target: { value: 'self | select node' } });
  fireEvent.click(screen.getByText('Проверить код'));
  expect(actions()).toEqual(['check_script']);
  push([{
    id: 1, line: 'check 1', status: 'valid', pending: false, error: null,
    position: null, records: [],
  }]);
  expect(screen.getByText(/Компиляция успешна/)).toBeTruthy();
});

test('быстрые команды доступны в списке рядом со строкой и сохраняют её черновик', () => {
  const { actions, commands } = setup();

  expect(screen.getByRole('button', { name: 'Терминал', pressed: true })).toBeTruthy();
  expect(screen.getByRole('region', { name: 'Журнал терминала' })).toBeTruthy();
  expect(screen.queryByText('Карта сети')).toBeNull();
  expect(screen.queryByText('Обзор')).toBeNull();
  expect(screen.queryByText('Проверить код')).toBeNull();
  expect(actions()).toEqual([]);

  fireEvent.change(commandInput(), { target: { value: 'nodes' } });
  const menu = screen.getByRole('combobox', { name: 'Быстрые команды' });
  fireEvent.change(menu, { target: { value: 'services' } });
  fireEvent.change(menu, { target: { value: 'jobs' } });
  expect(commands()).toEqual(['services', 'jobs']);
  expect(commandInput().value).toBe('nodes');
});

test('запуск скрипта открывает журнал и сохраняет текст в редакторе', () => {
  const { actions } = setup();
  fireEvent.click(screen.getByRole('button', { name: 'Редактор' }));
  const editor = document.querySelector('textarea')!;
  expect(editor.closest('details')).toBeNull();
  expect(screen.getByText('Диск').closest('details')?.open).toBe(false);

  fireEvent.input(editor, { target: { value: 'self | select node' } });
  fireEvent.click(screen.getByText('Запустить'));
  expect(actions()).toEqual(['run_script']);
  expect(screen.getByRole('button', { name: 'Терминал', pressed: true })).toBeTruthy();
  fireEvent.click(screen.getByRole('button', { name: 'Редактор' }));
  expect(document.querySelector('textarea')?.value).toBe('self | select node');
});

test('команда с карты подставляется один раз и только после открытия вкладки', () => {
  const act = jest.fn();
  const data = terminalData();
  const preset = { id: 1, line: 'trace 42' };
  const ui = render(<NetdmTerminalContent data={data} act={act} active={false} preset={preset} />);
  expect(commandInput().value).toBe('');

  ui.rerender(<NetdmTerminalContent data={data} act={act} active preset={preset} />);
  expect(commandInput().value).toBe('trace 42');
  expect(document.activeElement).toBe(commandInput());
  expect(act).not.toHaveBeenCalled();

  fireEvent.change(commandInput(), { target: { value: 'nodes' } });
  ui.rerender(<NetdmTerminalContent data={terminalData()} act={act} active preset={preset} />);
  expect(commandInput().value).toBe('nodes');
  fireEvent.keyDown(commandInput(), { key: 'Enter' });
  expect(act).toHaveBeenCalledTimes(1);
  expect(act).toHaveBeenCalledWith('run', { line: 'nodes' });
});

test('журнал показывает ожидание, затем ответ по возвращённому номеру операции', () => {
  const { commands, push } = setup();
  const request = {
    id: 1, line: 'invoke atmos.alarm.e42 read reason=inspect',
    records: [fields({ instance: 'atmos.alarm.e42', command: 'read', status: 'sent', operation: '987' })],
  };
  const result = { id: 2, line: 'result 987', records: [] };

  push([request]);
  expect(screen.getByText('sent')).toBeTruthy();
  expect(screen.queryByText('101.3')).toBeNull();
  fireEvent.click(screen.getByLabelText('Получить показания'));
  expect(commands()).toEqual(['result 987']);

  push([request, { ...result, pending: true, status: null }]);
  expect(screen.getByText('ожидание ответа по сети…')).toBeTruthy();
  expect(screen.queryByText('101.3')).toBeNull();

  push([request, { ...result, records: [fields({ pressureKPa: '101.3' })] }]);
  expect(screen.queryByText('ожидание ответа по сети…')).toBeNull();
  expect(screen.getByText('101.3')).toBeTruthy();
});
