import { BooleanLike } from 'common/react';
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';

import { Box, Button, Icon, NoticeBox, Section, Stack, Table } from '../components';
import { NetdmScriptIDE } from './NetdmScriptIDE';
import { SHELL_COMMANDS, tabComplete } from './netdmShell';

type Field = { name: string; value: string };

type Entry = {
  id: number;
  line: string;
  /** DM sends its booleans as 0/1: render them only through `!!`. */
  pending: BooleanLike;
  status: string | null;
  error: string | null;
  position: number | null;
  fuel: number | null;
  records: Field[][];
};

type NetworkEvent = {
  delivery: string;
  key: string;
  instance: string;
  schema: string;
  payload: string;
  truncated: BooleanLike;
  at: number;
};

export type NetdmTerminalData = {
  title: string;
  events?: NetworkEvent[];
  watches?: string[];
  /** Host and endpoint both acknowledged the current network session. */
  connectionReady?: BooleanLike;
  entries: Entry[];
  limit: number;
  scriptLimit: number;
  programsEnabled: BooleanLike;
  /** Names of programs kept on the device's media; null when the device has no media for them. */
  kept: string[] | null;
  disk: { id: string; name: string; file: string } | null;
  diskNotice: string | null;
  loadedScript: { id: number; source: string } | null;
};

const STATUS_TEXT: Record<string, string> = {
  parse_error: 'ошибка в строке',
  unknown_command: 'неизвестная команда',
  invalid_argument: 'неверные аргументы',
  fuel_exhausted: 'строка слишком дорогая',
  limit_exceeded: 'превышен предел',
  source_failed: 'команда не выполнена',
  no_answer: 'сетевой модуль не ответил',
  refused: 'запрос отклонён',
  unknown_program: 'программа недоступна',
};

const HELP_TOPICS = [
  { topic: '', title: 'Обзор' },
  { topic: 'basics', title: 'Команды' },
  { topic: 'services', title: 'Устройства' },
  { topic: 'api', title: 'API' },
  { topic: 'scripts', title: 'Скрипты' },
  { topic: 'programs', title: 'Программы' },
];

const TERMINAL_PANES = [
  { id: 'terminal', icon: 'terminal', label: 'Терминал' },
  { id: 'editor', icon: 'code', label: 'Редактор' },
  { id: 'help', icon: 'question-circle', label: 'Справка' },
] as const;

type TerminalPane = typeof TERMINAL_PANES[number]['id'];

const SCRIPT_EXAMPLES = {
  'Поиск серверов': 'services -type research.server | sort hops | first 3 | select instance hops',
  'Замер воздуха': '$alarms = services -type atmos.alarm | sort hops | first 1\nif $alarms\n  $alarms | invoke read reason=inspect\nend',
  'Таймер программы': 'every 10\n$state = self | select node state',
  'Реакция на событие': 'observe atmos.o2_sensor -key oxygen -projection panel.v1 -mode queue -pending 4\non events -key oxygen | where pressureKPa -gt 130\nservices -type machine.control | first 1 | invoke set_power on=false\nwait\n$result | select instance outcome',
};

const HISTORY_LIMIT = 32;
const SERVICE_NAME = /^[A-Za-z0-9._-]{1,64}$/;
const OPERATION_ID = /^[1-9][0-9]{0,18}$/;
const helpLine = (topic: string) => topic ? `help ${topic}` : 'help';
const valueOf = (fields: Field[], name: string) => fields.find(field => field.name === name)?.value;

/** Column names in the order the records first name them. */
export const columnsOf = (records: Field[][]): string[] => {
  const names: string[] = [];
  for (const record of records) {
    for (const field of record) {
      if (!names.includes(field.name)) {
        names.push(field.name);
      }
    }
  }
  return names;
};

const Records = (props: { entry: Entry; onCommand: (line: string) => void; onDraft: (line: string) => void; onStop: (id: string) => void }) => {
  const { entry, onCommand, onDraft, onStop } = props;
  const { records } = entry;
  const columns = columnsOf(records);
  const listingJobs = /^jobs(?:\s|$)/i.test(entry.line);
  const actions = records.map(record => {
    const instance = valueOf(record, 'instance');
    const type = valueOf(record, 'type');
    const operation = valueOf(record, 'operation');
    const program = valueOf(record, 'program');
    const state = valueOf(record, 'state');
    return {
      instance: instance && type && SERVICE_NAME.test(instance) ? instance : null,
      type: type && SERVICE_NAME.test(type) ? type : null,
      operation: operation && OPERATION_ID.test(operation) ? operation : null,
      alarm: type === 'atmos.alarm',
      alarmRead: !!instance?.startsWith('atmos.alarm.') && valueOf(record, 'command') === 'read',
      stop: /^programs(?:\s|$)/i.test(entry.line) && program && OPERATION_ID.test(program) &&
        state && !['done', 'faulted', 'stopped', 'migrated'].includes(state) ? program : null,
    };
  });
  const showActions = actions.some(action => action.instance || action.stop || (action.operation && (!listingJobs || action.alarmRead)));
  return (
    <Table>
      <Table.Row header>
        {columns.map((name) => (
          <Table.Cell key={name}>{name}</Table.Cell>
        ))}
        {showActions && <Table.Cell />}
      </Table.Row>
      {records.map((record, index) => {
        const { instance, type, operation, alarm, alarmRead, stop } = actions[index];
        return (
          <Table.Row key={index}>
            {columns.map((name) => (
              <Table.Cell key={name}>{valueOf(record, name) ?? ''}</Table.Cell>
            ))}
            {showActions && (
              <Table.Cell collapsing>
                {instance && <Button icon="route" aria-label="Показать маршрут" tooltip="Показать маршрут" onClick={() => onCommand(`route ${instance}`)} />}
                {instance && type && <Button icon="code" aria-label="Схема сервиса" tooltip="Посмотреть команды и их аргументы" onClick={() => onCommand(`api ${type}`)} />}
                {instance && <Button icon="terminal" aria-label="Подготовить вызов" tooltip="Заполнить командную строку, не отправляя вызов" onClick={() => onDraft(`invoke ${instance} `)} />}
                {instance && <Button icon="bell" aria-label="Подготовить подписку" tooltip="Заполнить командную строку для подписки" onClick={() => onDraft(`watch ${instance}`)} />}
                {instance && alarm && <Button icon="tachometer-alt" aria-label="Снять показания" tooltip="Снять показания" onClick={() => onCommand(`invoke ${instance} read reason=inspect`)} />}
                {operation && !listingJobs && <Button icon="tasks" aria-label="Проверить доставку" tooltip="Проверить доставку" onClick={() => onCommand(`jobs | where operation -eq "${operation}"`)} />}
                {operation && alarmRead && <Button icon="poll" aria-label="Получить показания" tooltip="Получить показания" onClick={() => onCommand(`result ${operation}`)} />}
                {stop && <Button.Confirm icon="stop" content="Остановить" confirmContent="Остановить программу?" onClick={() => onStop(stop)} />}
              </Table.Cell>
            )}
          </Table.Row>
        );
      })}
    </Table>
  );
};

const failedEntry = (entry: Entry) => !entry.pending && !['ok', 'started', 'running', 'stopped', 'migrated'].includes(entry.status || '');

const EntryView = (props: { entry: Entry; onCommand: (line: string) => void; onDraft: (line: string) => void; onStop: (id: string) => void }) => {
  const { entry, onCommand, onDraft, onStop } = props;
  const failed = failedEntry(entry);
  return (
    <Box mb={1}>
      <Box bold fontFamily="monospace" style={{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}>
        {'> '}
        {entry.line}
      </Box>
      {!!entry.pending && <Box color="label">ожидание ответа по сети…</Box>}
      {failed && (
        <NoticeBox danger>
          {STATUS_TEXT[entry.status || ''] || entry.status}
          {entry.error ? `: ${entry.error}` : ''}
          {typeof entry.position === 'number' ? ` (позиция ${entry.position + 1})` : ''}
        </NoticeBox>
      )}
      {!entry.pending && !failed && entry.records.length === 0 && <Box color="label">нет записей</Box>}
      {entry.records.length > 0 && <Records entry={entry} onCommand={onCommand} onDraft={onDraft} onStop={onStop} />}
    </Box>
  );
};

const Help = (props: { entry?: Entry; topic: string; hasDraft: boolean; onTopic: (topic: string) => void;
  onExample: (example: string) => void }) => {
  const { entry, topic, hasDraft, onTopic, onExample } = props;
  return (
    <Section fill scrollable className="NetdmTerminalWorkspace__help">
      <div className="NetdmTerminalWorkspace__helpTopics">
        {HELP_TOPICS.map(item => (
          <Button key={item.topic} selected={item.topic === topic} onClick={() => onTopic(item.topic)}>{item.title}</Button>
        ))}
      </div>
      {!entry || entry.pending ? (
        <Box color="label">Ожидание ответа по сети…</Box>
      ) : failedEntry(entry) ? (
        <NoticeBox warning>Справка недоступна. Выберите раздел ещё раз, когда связь восстановится.</NoticeBox>
      ) : entry.records.map((record, index) => {
        const syntax = valueOf(record, 'syntax');
        const description = valueOf(record, 'description');
        const example = valueOf(record, 'example');
        return (
          <Box key={index} mb={1}>
            <Box bold color="good" fontFamily="monospace">{syntax}</Box>
            <Box>{description}</Box>
            {example && (
              <Button
                mt={0.25}
                icon="terminal"
                disabled={hasDraft}
                tooltip={hasDraft ? 'Сначала выполните или очистите черновик команды' : 'Подставить пример в командную строку'}
                onClick={() => onExample(example)}>
                {example}
              </Button>
            )}
          </Box>
        );
      })}
    </Section>
  );
};

const TerminalNavigation = ({ pane, onPane }: {
  pane: TerminalPane;
  onPane: (pane: TerminalPane) => void;
}) => {
  return (
    <div className="NetdmTerminalWorkspace__tabs" role="group" aria-label="Режим работы">
      {TERMINAL_PANES.map(({ id, icon, label }) => (
        <button key={id} type="button" className="NetdmTerminalWorkspace__tab" data-pane={id}
          aria-pressed={pane === id} onClick={() => onPane(id)}>
          <Icon name={icon} />
          {label}
        </button>
      ))}
    </div>
  );
};

export const NetdmTerminalEvents = ({ data, onCommand }: {
  data: Pick<NetdmTerminalData, 'events' | 'watches'>;
  onCommand: (command: string) => void;
}) => {
  const { events = [], watches = [] } = data;
  const watchKeys = watches.filter(key => SERVICE_NAME.test(key));
  return (
    <Section title="Доставленные события">
      {watchKeys.length > 0 && (
        <Box mb={1}>
          <Box color="label" inline mr={1}>Подписки</Box>
          {watchKeys.map(key => (
            <Button key={key} icon="times" content={key} tooltip="Отписаться"
              onClick={() => onCommand(`unwatch ${key}`)} />
          ))}
        </Box>
      )}
      {events.length === 0 && <Box color="label">Сюда поступают события сервисов, на которые вы подписались.</Box>}
      {events.map(event => (
        <Section key={event.delivery} title={`${event.instance} · ${event.schema}`}>
          <Box color="label">Подписка {event.key} · Доставка {event.delivery}</Box>
          <Box fontFamily="monospace" style={{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}>
            {event.payload}{!!event.truncated && ' … (обрезано)'}
          </Box>
        </Section>
      ))}
    </Section>
  );
};

const editorCheckState = (entries: Entry[], checkTag: number | null, checkedSource: string, script: string) => {
  if (checkTag === null) return undefined;
  const entry = [...entries].reverse().find(item => item.line === `check ${checkTag}`);
  return {
    status: entry?.status ?? null,
    error: entry?.error,
    position: entry?.position,
    pending: !entry || !!entry.pending,
    stale: checkedSource !== script,
  };
};

export const NetdmTerminalContent = ({ data, act, active = true, preset }: {
  data: NetdmTerminalData;
  act: (command: string, params?: Record<string, unknown>) => void;
  active?: boolean;
  preset?: { id: number; line: string };
}) => {
  const [line, setLine] = useState('');
  const [history, setHistory] = useState<string[]>([]);
  const [historyIndex, setHistoryIndex] = useState(0);
  const [draft, setDraft] = useState('');
  const [script, setScript] = useState('');
  const [programName, setProgramName] = useState('');
  const [keepProgram, setKeepProgram] = useState(false);
  const [pane, setPane] = useState<TerminalPane>('terminal');
  const [checkedSource, setCheckedSource] = useState('');
  const [checkTag, setCheckTag] = useState<number | null>(null);
  const checkSerial = useRef(0);
  const [helpTopic, setHelpTopic] = useState('');
  const commandInput = useRef<HTMLInputElement>(null);
  const log = useRef<HTMLDivElement>(null);
  const followLog = useRef(true);
  const handledPreset = useRef<number>(null);
  const focusPreset = useRef(false);
  const { disk, diskNotice, loadedScript } = data;
  const loadedId = loadedScript?.id;
  const loadedSource = loadedScript?.source;
  useEffect(() => {
    if (loadedSource !== undefined) {
      setScript(loadedSource);
    }
  }, [loadedId, loadedSource]);
  const canRun = !!script.trim() && script.length <= data.scriptLimit;
  const canRunOnce = canRun && !/^(observe|on|every)\b/.test(script.trimStart());
  const checkState = editorCheckState(data.entries, checkTag, checkedSource, script);
  const helpEntry = pane === 'help' ? [...data.entries].reverse().find(entry => entry.line === helpLine(helpTopic)) : undefined;
  // Dynamic completion pools: instances from the last `services`, nodes from the last `nodes`/`trace`.
  const completion = useMemo(() => {
    const lastWith = (pattern: RegExp, field: string) => {
      const entry = [...data.entries].reverse().find(candidate => pattern.test(candidate.line));
      if (!entry?.records) {
        return [];
      }
      return entry.records
        .map(record => record.find(cell => cell.name === field)?.value)
        .filter((value): value is string => typeof value === 'string' && value.length > 0);
    };
    return {
      instances: lastWith(/^services(?:\s|$)/i, 'instance'),
      nodes: [...new Set([...lastWith(/^nodes(?:\s|$)/i, 'node'), ...lastWith(/^trace(?:\s|$)/i, 'node')])],
      types: [...new Set(lastWith(/^services(?:\s|$)/i, 'type'))],
    };
  }, [data.entries]);
  const usageHint = useMemo(() => {
    const first = line.trim().split(/\s+/)[0];
    return SHELL_COMMANDS.find(command => command.name === first)?.usage ?? null;
  }, [line]);
  const presetId = preset?.id;
  const presetLine = preset?.line;
  useEffect(() => {
    if (!active || presetId === undefined || presetLine === undefined || handledPreset.current === presetId) {
      return;
    }
    handledPreset.current = presetId;
    focusPreset.current = true;
    setLine(presetLine);
    setHistoryIndex(history.length);
    setDraft('');
    setPane('terminal');
  }, [active, history.length, presetId, presetLine]);
  useEffect(() => {
    const input = commandInput.current;
    // Keep dock navigation on the tab rail until the map explicitly opens a draft.
    if (active && input && focusPreset.current) {
      input.focus();
      focusPreset.current = false;
    }
  }, [active, pane, presetId]);
  useLayoutEffect(() => {
    if (active && log.current && followLog.current) {
      log.current.scrollTop = log.current.scrollHeight;
    }
  });

  const run = (command: string) => {
    followLog.current = true;
    act('run', { line: command });
  };
  const openHelp = (topic: string) => {
    setHelpTopic(topic);
    run(helpLine(topic));
  };
  const recall = (index: number) => {
    if (index < 0 || index > history.length || historyIndex === index) {
      return;
    }
    if (historyIndex === history.length) {
      setDraft(line);
    }
    setHistoryIndex(index);
    setLine(history[index] ?? draft);
  };
  const send = (text: string) => {
    const trimmed = text.trim();
    if (trimmed.length > 0 && trimmed.length <= data.limit) {
      run(trimmed);
      const next = [...history.filter(entry => entry !== trimmed), trimmed].slice(-HISTORY_LIMIT);
      setHistory(next);
      setHistoryIndex(next.length);
      setDraft('');
      setLine('');
    }
  };
  const selectPane = (next: TerminalPane) => {
    if (next === pane) return;
    setPane(next);
    if (next === 'help') openHelp('');
  };
  const launchScript = (action: string, params: Record<string, unknown>) => {
    followLog.current = true;
    act(action, params);
    setPane('terminal');
  };

  return (
    <div className="NetdmTerminalWorkspace">
      <Stack vertical fill>
        <Stack.Item>
          <TerminalNavigation pane={pane} onPane={selectPane} />
        </Stack.Item>
        {pane !== 'editor' && (
          <Stack.Item grow>
            {pane === 'help' ? (
              <Help
                entry={helpEntry}
                topic={helpTopic}
                hasDraft={!!line.trim()}
                onTopic={openHelp}
                onExample={example => {
                  setLine(example);
                  setHistoryIndex(history.length);
                  setPane('terminal');
                }} />
            ) : (
              <Section
                key="terminal-log"
                className="NetdmTerminalWorkspace__journal"
                role="region"
                aria-label="Журнал терминала"
                fill
                scrollable
                scrollableRef={log}
                onScroll={() => {
                  const node = log.current;
                  if (node) {
                    followLog.current = node.scrollHeight - node.scrollTop - node.clientHeight < 32;
                  }
                }}>
                {data.entries.length === 0 && <Box color="label">Ответы на команды появятся здесь.</Box>}
                {data.entries.map(entry => (
                  <EntryView key={entry.id} entry={entry} onCommand={run}
                    onDraft={command => { setLine(command); setPane('terminal'); }}
                    onStop={program => act('stop_program', { program })} />
                ))}
              </Section>
            )}
          </Stack.Item>
        )}
        {pane === 'editor' && (
          <Stack.Item grow>
            <Section scrollable fill className="NetdmTerminalWorkspace__editor">
              <NetdmScriptIDE
                key={loadedId}
                source={script}
                onChange={setScript}
                limit={data.scriptLimit}
                pool={completion}
                check={checkState}
                actions={
                  <>
                    {!script.trim() && (
                      <select className="NetdmTerminalWorkspace__commandMenu" aria-label="Примеры скриптов" value=""
                        onChange={event => {
                          const example = SCRIPT_EXAMPLES[event.currentTarget.value as keyof typeof SCRIPT_EXAMPLES];
                          if (example) setScript(example);
                        }}>
                        <option value="" disabled>Примеры</option>
                        {Object.keys(SCRIPT_EXAMPLES).map(name => <option key={name}>{name}</option>)}
                      </select>
                    )}
                    <Button
                      icon="play"
                      content="Запустить"
                      disabled={!canRunOnce}
                      tooltip="Однократный скрипт не допускает on/observe/every; запустите его как программу."
                      onClick={() => launchScript('run_script', { source: script })}
                    />
                  </>
                }
                onCheck={() => {
                  const tag = ++checkSerial.current;
                  setCheckTag(tag);
                  setCheckedSource(script);
                  act('check_script', { source: script, name: SERVICE_NAME.test(programName) ? programName : 'draft', tag });
                }}
              />
              <details className="NetdmTerminalWorkspace__editorTools">
                <summary>{data.programsEnabled ? 'Программы и диск' : 'Диск'}</summary>
                {!!data.programsEnabled && (
                  <div className="NetdmTerminalWorkspace__programControls">
                    <input
                      className="NetdmTerminalWorkspace__programName"
                      aria-label="Имя программы"
                      maxLength={32}
                      placeholder="Имя программы"
                      value={programName}
                      onChange={event => setProgramName(event.currentTarget.value)}
                    />
                    <Button
                      icon="play"
                      content="Запустить программу"
                      disabled={!canRun || !/^[a-zA-Z0-9._-]+$/.test(programName)}
                      onClick={() => launchScript('start_program', { name: programName, source: script, keep: keepProgram })}
                    />
                    {!!data.kept && (
                      <Button.Checkbox
                        checked={keepProgram}
                        content="Хранить на устройстве"
                        tooltip="Программа записывается на устройство и запускается при каждом его подключении к сети."
                        onClick={() => setKeepProgram(!keepProgram)}
                      />
                    )}
                  </div>
                )}
                {!!data.programsEnabled && !!data.kept && data.kept.length > 0 && (
                  <Box mt={0.5}>
                    <Box inline color="label" mr={0.5}>На устройстве:</Box>
                    {data.kept.map((name) => (
                      <Button.Confirm
                        key={name}
                        icon="times"
                        content={name}
                        confirmContent={`Не хранить ${name}?`}
                        onClick={() => act('forget_program', { name })}
                      />
                    ))}
                  </Box>
                )}
                {disk ? (
                  <Box key={`${disk.id}/${disk.file}`} mt={0.5}>
                    <Box color="label">{disk.name}{disk.file ? ' · netdm.NDS1' : ''}</Box>
                    {disk.file ? (
                      <Button.Confirm
                        icon="save"
                        content="Перезаписать"
                        confirmContent="Перезаписать netdm.NDS1?"
                        disabled={!canRun}
                        onClick={() => act('save_disk', { disk: disk.id, file: disk.file, source: script })}
                      />
                    ) : (
                      <Button
                        icon="save"
                        content="На диск"
                        disabled={!canRun}
                        onClick={() => act('save_disk', { disk: disk.id, file: disk.file, source: script })}
                      />
                    )}
                    <Button.Confirm
                      icon="folder-open"
                      content="В редактор"
                      confirmContent="Заменить текст редактора?"
                      disabled={!disk.file}
                      onClick={() => act('load_disk', { disk: disk.id, file: disk.file })}
                    />
                    <Button
                      icon="play"
                      content="Запустить с диска"
                      disabled={!disk.file}
                      onClick={() => launchScript('run_disk', { disk: disk.id, file: disk.file })}
                    />
                  </Box>
                ) : (
                  <Box color="label" mt={0.5}>Возьмите Data Disk в руку для записи или чтения.</Box>
                )}
              </details>
              {diskNotice && <Box mt={0.5}>{diskNotice}</Box>}
            </Section>
          </Stack.Item>
        )}
        {pane === 'terminal' && (
          <Stack.Item>
            <div className="NetdmTerminalWorkspace__composer">
              <select className="NetdmTerminalWorkspace__commandMenu" aria-label="Быстрые команды" value=""
                onChange={event => { if (event.currentTarget.value) run(event.currentTarget.value); }}>
                <option value="" disabled>Команды</option>
                <option value="services">Сервисы</option>
                <option value="jobs">Доставка</option>
                {!!data.programsEnabled && <option value="programs">Программы</option>}
              </select>
              <input
                ref={commandInput}
                className="NetdmTerminalWorkspace__commandInput"
                aria-label="Командная строка"
                autoComplete="off"
                spellCheck={false}
                maxLength={data.limit}
                placeholder="Введите команду"
                title="Tab — автодополнение · ↑↓ — история · Enter — выполнить"
                value={line}
                onChange={event => setLine(event.currentTarget.value)}
                onKeyDown={event => {
                  if (event.nativeEvent.isComposing) {
                    return;
                  }
                  if (event.key === 'Tab' && !event.shiftKey) {
                    const completed = tabComplete(line, completion);
                    if (completed !== line) {
                      event.preventDefault();
                      setLine(completed);
                    }
                    return;
                  }
                  if (event.key === 'Enter') {
                    event.preventDefault();
                    send(line);
                  } else if (event.key === 'ArrowUp' || event.key === 'ArrowDown') {
                    event.preventDefault();
                    recall(historyIndex + (event.key === 'ArrowUp' ? -1 : 1));
                  }
                }} />
              <button className="NetdmTerminalWorkspace__execute" type="button" disabled={!line.trim()}
                onClick={() => send(line)}>
                Выполнить
              </button>
              {data.entries.length > 0 && (
                <button className="NetdmTerminalWorkspace__clear" type="button" aria-label="Очистить журнал"
                  title="Очистить журнал" onClick={() => act('clear')}>
                  <Icon name="eraser" />
                </button>
              )}
            </div>
            {usageHint && <div className="NetdmTerminalWorkspace__usage">{usageHint}</div>}
          </Stack.Item>
        )}
      </Stack>
    </div>
  );
};
