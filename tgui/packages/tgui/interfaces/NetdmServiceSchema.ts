import { DeviceEntry, DeviceRecord } from './NetdmDeviceState';

/**
 * The general-purpose device UI is driven by Host's public shell API records.
 * This module never guesses a command's contract from its service name.
 */
export type ServiceAction = {
  command: string;
  request: string;
  result: string;
  args: string;
  returns: string;
};

export type ServiceField = {
  name: string;
  type: 'text' | 'multiline' | 'integer' | 'number' | 'boolean' | 'enum';
  required: boolean;
  spec: string;
  choices: string[];
  min: number | null;
  max: number | null;
  maxLength: number | null;
};

export const safeServiceIdentifier = (value: string): boolean =>
  /^[a-zA-Z0-9._-]{1,64}$/.test(value);

const value = (record: DeviceRecord[], key: string) =>
  record.find(field => field.name === key)?.value ?? '';

export const latestApiReply = (entries: DeviceEntry[], line: string): DeviceEntry | undefined =>
  [...entries].reverse().find(entry => entry.line === line);

export const serviceActions = (entry: DeviceEntry | undefined, type: string): ServiceAction[] => {
  if (!entry || entry.pending || entry.status !== 'ok' || entry.line !== `api ${type}`) return [];
  const names = new Set<string>();
  return entry.records.flatMap(fields => {
    const command = value(fields, 'command');
    if (value(fields, 'type') !== type || !safeServiceIdentifier(command) || names.has(command)) return [];
    names.add(command);
    return [{
      command,
      request: value(fields, 'request'),
      result: value(fields, 'result'),
      args: value(fields, 'args'),
      returns: value(fields, 'returns'),
    }];
  });
};

export const actionFields = (entry: DeviceEntry | undefined, type: string, command: string): ServiceField[] => {
  if (!entry || entry.pending || entry.status !== 'ok' ||
      entry.line !== `api ${type} ${command}`) return [];
  const seen = new Set<string>();
  return entry.records.flatMap(record => {
    if (value(record, 'how') !== 'request') return [];
    const name = value(record, 'field');
    const kind = value(record, 'type');
    if (!safeServiceIdentifier(name) || seen.has(name) ||
        !['text', 'multiline', 'integer', 'number', 'boolean', 'enum'].includes(kind)) return [];
    seen.add(name);
    const spec = value(record, 'spec');
    const choices = kind === 'enum' && spec.startsWith('=')
      ? spec.slice(1).split('|').filter(item => /^[a-zA-Z0-9._-]+$/.test(item))
      : [];
    const limits = spec.match(/\[(-?\d+(?:\.\d+)?)\.\.(-?\d+(?:\.\d+)?)\]/);
    const maxLength = spec.match(/≤(\d+)/);
    return [{
      name, type: kind as ServiceField['type'],
      required: value(record, 'required') === 'yes',
      spec,
      choices,
      min: limits ? Number(limits[1]) : null,
      max: limits ? Number(limits[2]) : null,
      maxLength: maxLength ? Number(maxLength[1]) : null,
    }];
  });
};

const safeToken = /^[a-zA-Z0-9._:@,-]+$/;

/** Deliberately reject whitespace and shell punctuation instead of trying to escape arbitrary text.
 * Advanced users can send complex arguments from the real shell after reviewing the wire schema. */
export const argumentError = (field: ServiceField, raw: string): string | null => {
  if (!raw) return field.required ? 'Обязательное поле' : null;
  if (field.type === 'boolean')
    return ['true', 'false'].includes(raw) ? null : 'Выберите да или нет';
  if (field.type === 'enum')
    return field.choices.includes(raw) ? null : 'Выберите доступное значение';
  if (field.type === 'integer' || field.type === 'number') {
    if (!/^-?\d+(?:\.\d+)?$/.test(raw) ||
        (field.type === 'integer' && !/^-?\d+$/.test(raw))) return 'Введите число';
    const number = Number(raw);
    if (!Number.isFinite(number) || !Number.isSafeInteger(number) && field.type === 'integer')
      return 'Число вне допустимого диапазона';
    if (field.min !== null && number < field.min || field.max !== null && number > field.max)
      return 'Число вне разрешённых границ';
    return null;
  }
  if (field.maxLength !== null && raw.length > field.maxLength) return 'Слишком длинное значение';
  return safeToken.test(raw) && raw.length <= 256
    ? null
    : 'Для этого поля используйте латиницу, цифры и символы . _ - : @ ,';
};

export const invocationLine = (
  instance: string, command: string, fields: ServiceField[], values: Record<string, string>,
): string | null => {
  if (!safeServiceIdentifier(instance) || !safeServiceIdentifier(command)) return null;
  if (fields.some(field => argumentError(field, values[field.name] ?? '') !== null)) return null;
  const args = fields.flatMap(field => {
    const data = values[field.name] ?? '';
    return data ? [`${field.name}=${data}`] : [];
  });
  // The shell has a separate line length budget; do not exceed it even for valid fields.
  const line = [`invoke ${instance} ${command}`, ...args].join(' ');
  return line.length <= 1024 ? line : null;
};

export const actionLabel = (command: string): string => ({
  status: 'Получить состояние',
  read: 'Получить показания',
  sample: 'Запросить измерение',
  set_power: 'Управление питанием',
  set_state: 'Изменить состояние',
  set_alert: 'Управление тревогой',
  acquire: 'Запросить доступ',
  research: 'Разблокировать исследование',
  backup: 'Создать резервную копию',
  restore: 'Восстановить данные',
}[command] ?? command.replace(/_/g, ' '));

/** Conservative: unrecognized actions are changes, never assume they are harmless. */
export const isReadAction = (command: string): boolean =>
  ['read', 'sample', 'status'].includes(command);
