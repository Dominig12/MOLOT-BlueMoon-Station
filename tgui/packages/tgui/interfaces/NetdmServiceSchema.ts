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

const enumChoices = (spec: string): string[] => {
  // The compact shell response replaces "=" inside record values with spaces.
  const choices = spec.trim().replace(/^=/, '').split('|').map(choice => choice.trim());
  return choices.every(safeServiceIdentifier) ? [...new Set(choices)] : [];
};

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
    const spec = value(record, 'spec').trim();
    const choices = kind === 'enum' ? enumChoices(spec) : [];
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
  if (field.type === 'boolean') {
    return ['true', 'false'].includes(raw) ? null : 'Выберите да или нет';
  }
  if (field.type === 'enum') {
    return field.choices.includes(raw) ? null : 'Выберите доступное значение';
  }
  if (field.type === 'integer' || field.type === 'number') {
    if (!/^-?\d+(?:\.\d+)?$/.test(raw) ||
        (field.type === 'integer' && !/^-?\d+$/.test(raw))) {
      return 'Введите число';
    }
    const number = Number(raw);
    if (!Number.isFinite(number) || !Number.isSafeInteger(number) && field.type === 'integer') {
      return 'Число вне допустимого диапазона';
    }
    if (field.min !== null && number < field.min || field.max !== null && number > field.max) {
      return 'Число вне разрешённых границ';
    }
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
  link_state: 'Проверить состояние связей',
  trace: 'Проверить путь до узла',
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
  ['read', 'sample', 'status', 'link_state', 'trace'].includes(command);

const PDA_WORKFLOW = 'Отправляйте сообщения из приложения «Сообщения» на КПК. КПК подставляет данные отправителя и идентификатор сообщения.';
const RESEARCH_WORKFLOW = 'Используйте консоль R&D для исследований, переноса очков и работы с диском. Консоль подставляет данные для операции.';

// Presentation guides match the request schema reported by Host. Authorization remains with the game.
const DEVICE_WORKFLOWS: Readonly<Partial<Record<string, string>>> = {
  'machine.door_set': 'Привязанная кнопка создаёт идентификатор нажатия press автоматически.',
  'machine.door_control_request': 'Для сетевого управления откройте «Панель шлюза» в карточке узла. Она доступна операторам с правами управления шлюзом.',
  'camera.acquire': 'Выберите камеру на охранной консоли. Она создаёт идентификатор подключения.',
  'atmos.alert_request': 'Используйте «Поднять тревогу» или «Снять тревогу» в карточке панели. Идентификатор запроса создаётся автоматически.',
  'pda.message': PDA_WORKFLOW,
  'pda.relay': PDA_WORKFLOW,
  'pda.delivery': PDA_WORKFLOW,
  'radio.uplink': 'Передайте сообщение через гарнитуру или рацию. Идентификатор передачи создаётся автоматически.',
  'research.request': RESEARCH_WORKFLOW,
  'research.sync_request': RESEARCH_WORKFLOW,
  'research.transfer_request': RESEARCH_WORKFLOW,
  'research.transfer_authorization': RESEARCH_WORKFLOW,
  'research.disk_request': RESEARCH_WORKFLOW,
};

const SERVICE_WORKFLOWS: Readonly<Partial<Record<string, string>>> = {
  'network.shell': 'Пользуйтесь вкладками «Терминал», «Маршруты» и «Чат». Они подставляют параметры сетевой сессии.',
  'network.query': 'Список сервисов, маршруты и журнал команд доступны в терминале через services, route и jobs.',
};

function ownEntry<T>(record: Readonly<Partial<Record<string, T>>>, key: string): T | undefined {
  return Object.prototype.hasOwnProperty.call(record, key) ? record[key] : undefined;
}

export const serviceWorkflow = (type: string, action: ServiceAction): string | undefined =>
  ownEntry(DEVICE_WORKFLOWS, action.request) ?? ownEntry(SERVICE_WORKFLOWS, type);

type FieldGuide = {
  label: string;
  hint?: string;
  labels?: Readonly<Partial<Record<string, string>>>;
};

const INSPECT_REASON: FieldGuide = {
  label: 'Причина запроса',
  labels: { inspect: 'Осмотр', refresh: 'Обновление' },
};

type FieldGuides = Readonly<Partial<Record<string, FieldGuide>>>;

const FIELD_GUIDES: Readonly<Partial<Record<string, FieldGuides>>> = {
  'machine.set_power': {
    on: { label: 'Питание', labels: { true: 'Включить', false: 'Выключить' } },
  },
  'atmos.alarm_read': { reason: INSPECT_REASON },
  'atmos.sample_request': {
    reason: {
      label: 'Причина замера',
      hint: 'Для обычного замера оставьте поле пустым.',
      labels: { subscribe: 'Подписка', refresh: 'Обновление' },
    },
  },
  'network.link_request': { reason: INSPECT_REASON },
  'network.trace_request': {
    node: {
      label: 'Номер узла',
      hint: 'Выберите узел на карте и скопируйте число из заголовка «Узел N».',
    },
  },
  'research.status_request': {
    reason: {
      label: 'Причина запроса',
      labels: { open: 'Открытие', refresh: 'Обновление' },
    },
  },
};

export const serviceFieldGuide = (request: string, name: string): FieldGuide | undefined => {
  const fields = ownEntry(FIELD_GUIDES, request);
  return fields && ownEntry(fields, name);
};
