import { insertCompletion, scriptLocation, scriptOutline, scriptSuggestions } from './NetdmScriptIDE';

test('синтаксическое дерево выделяет наблюдения и фазы без исполнения кода', () => {
  const source = 'observe atmos.alarm.e12 -key alert\non events -key alert | where alarm -eq true\nif $event\nwait\nend';
  expect(scriptOutline(source).map(item => [item.line, item.label.split(' ')[0]])).toEqual([
    [1, 'observe'], [2, 'on'], [3, 'if'], [4, 'wait'],
  ]);
  expect(scriptLocation(source, source.indexOf('if'))).toEqual({ line: 3, column: 1 });
});

test('подсказки используют только известные экземпляры и локальные имена подписок', () => {
  const source = 'observe atmos.alarm.e12 -key alert\non events -key a';
  expect(scriptSuggestions(source, source.length)).toContain('alert');
  const before = 'observe atm';
  expect(scriptSuggestions(before, before.length, {
    instances: ['atmos.alarm.e12', 'atmos.alarm.e13', 'secret.invisible'],
  })).toEqual(expect.arrayContaining(['atmos.alarm.e12', 'atmos.alarm.e13']));
  expect(scriptSuggestions(before, before.length, {
    instances: ['atmos.alarm.e12'],
  })).not.toContain('secret.invisible');
});

test('завершение токена не удаляет последующий код', () => {
  const source = 'observe atmos.al | count';
  const choice = insertCompletion(source, 'observe atmos.al'.length, 'atmos.alarm.e12');
  expect(choice.source).toBe('observe atmos.alarm.e12  | count');
  expect(choice.caret).toBe('observe atmos.alarm.e12 '.length);
});
