/**
 * P13.6 · shell completion for the network console.
 *
 * The catalogue is the same surface the Host advertises with the `commands` command; the dynamic pool is
 * what the current window knows: service instances and wire ids. Completion is prefix-only and never runs
 * anything: it just moves text into the input, so it cannot bypass the shell's budgets or policies.
 */

export type ShellCommandInfo = {
  name: string;
  kind: 'source' | 'filter' | 'action';
  usage: string;
  description: string;
};

/** First token of a line: sources, filters and the two actions (kept in sync with ShellHost.Catalogue). */
export const SHELL_COMMANDS: readonly ShellCommandInfo[] = [
  { name: 'self', kind: 'source', usage: 'self', description: 'Свой узел, питание и порты.' },
  { name: 'links', kind: 'source', usage: 'links', description: 'Соседние порты и их состояние.' },
  { name: 'nodes', kind: 'source', usage: 'nodes', description: 'Известные узлы сети.' },
  { name: 'services', kind: 'source', usage: 'services [-type T] [-prefix P] [-hops N]', description: 'Достижимые сервисы.' },
  { name: 'api', kind: 'source', usage: 'api [serviceType [command]]', description: 'API сервисов: команды, аргументы, схемы.' },
  { name: 'commands', kind: 'source', usage: 'commands', description: 'Все команды оболочки.' },
  { name: 'route', kind: 'source', usage: 'route <instance>', description: 'Путь до сервиса.' },
  { name: 'trace', kind: 'source', usage: 'trace <node>', description: 'Путь до узла.' },
  { name: 'jobs', kind: 'source', usage: 'jobs', description: 'Операции и их исход.' },
  { name: 'result', kind: 'source', usage: 'result <operation>', description: 'Результат операции.' },
  { name: 'programs', kind: 'source', usage: 'programs', description: 'Фоновые программы.' },
  { name: 'help', kind: 'source', usage: 'help [topic]', description: 'Справка по темам.' },
  { name: 'where', kind: 'filter', usage: 'where <field> <op> <value>', description: 'Фильтр записей.' },
  { name: 'select', kind: 'filter', usage: 'select <field>...', description: 'Оставить поля.' },
  { name: 'sort', kind: 'filter', usage: 'sort <field> [-desc]', description: 'Сортировка.' },
  { name: 'first', kind: 'filter', usage: 'first [N]', description: 'Первые N записей.' },
  { name: 'last', kind: 'filter', usage: 'last [N]', description: 'Последние N записей.' },
  { name: 'count', kind: 'filter', usage: 'count', description: 'Сколько записей.' },
  { name: 'invoke', kind: 'action', usage: 'invoke <instance> <command> [name=value…]', description: 'Команда сервису.' },
  { name: 'publish', kind: 'action', usage: '… | publish', description: 'Опубликовать записи.' },
];

export const HELP_TOPICS = ['basics', 'services', 'api', 'scripts', 'programs'] as const;

export type ShellDynamicPool = {
  /** Service instances the window has discovered. */
  instances?: readonly string[];
  /** Known wire node ids. */
  nodes?: readonly string[];
  /** Service types seen on the network: `api <type>` and `services -type <type>`. */
  types?: readonly string[];
};

const firstTokenPool = SHELL_COMMANDS.map(command => command.name);

const commonPrefix = (words: readonly string[]): string => {
  if (words.length === 0) {
    return '';
  }
  let prefix = words[0];
  for (const word of words.slice(1)) {
    let index = 0;
    while (index < prefix.length && index < word.length && prefix[index] === word[index]) {
      index++;
    }
    prefix = prefix.slice(0, index);
    if (!prefix) {
      break;
    }
  }
  return prefix;
};

/** Candidates for the token under the cursor (the line is completed from the end, like a terminal). */
export const completionCandidates = (
  line: string,
  dynamic: ShellDynamicPool = {},
  limit = 24,
): string[] => {
  const endsWithSpace = /\s$/.test(line);
  const head = line.replace(/\s*$/, '');
  const tokens = head.length > 0 ? head.split(/\s+/) : [];
  const token = endsWithSpace ? '' : tokens[tokens.length - 1] ?? '';
  const first = endsWithSpace ? tokens.length === 0 : tokens.length <= 1;
  const pool = first
    ? firstTokenPool
    : [...new Set([...(dynamic.instances ?? []), ...(dynamic.nodes ?? []), ...(dynamic.types ?? [])])];
  return [...new Set(pool)]
    .filter(value => value.startsWith(token))
    .sort()
    .slice(0, limit);
};

/**
 * Text for the Tab key: completes a unique candidate and adds a space, otherwise inserts the common
 * prefix of the candidates. When nothing matches the line is returned unchanged.
 */
export const tabComplete = (line: string, dynamic: ShellDynamicPool = {}): string => {
  const candidates = completionCandidates(line, dynamic);
  if (candidates.length === 0) {
    return line;
  }
  const endsWithSpace = /\s$/.test(line);
  const head = line.replace(/\s*$/, '');
  const token = endsWithSpace ? '' : head.split(/\s+/).pop() ?? '';
  const before = endsWithSpace ? (head.length > 0 ? `${head} ` : '') : line.slice(0, line.length - token.length);
  if (candidates.length === 1) {
    return `${before}${candidates[0]} `;
  }
  const prefix = commonPrefix(candidates);
  return prefix.length > token.length ? `${before}${prefix}` : line;
};
