import { BooleanLike } from 'common/react';
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';

import { useBackend } from '../backend';
import { Box, Button, Dropdown, Input, NoticeBox, Section, Stack, Table } from '../components';
import { Window } from '../layouts';
import { NetdmHome } from './NetdmHome';
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

type Data = {
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
    <Section fill scrollable title="Справка"
      buttons={HELP_TOPICS.map(item => (
        <Button key={item.topic} selected={item.topic === topic} onClick={() => onTopic(item.topic)}>{item.title}</Button>
      ))}>
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

const terminalSize = (simpleView: boolean, editingScript: boolean) => {
  if (simpleView) return { width: 820, height: 650 };
  if (editingScript) return { width: 940, height: 720 };
  return { width: 760, height: 560 };
};

export const NetdmTerminal = () => {
  const { act, data } = useBackend<Data>();
  const [line, setLine] = useState('');
  const [history, setHistory] = useState<string[]>([]);
  const [historyIndex, setHistoryIndex] = useState(0);
  const [draft, setDraft] = useState('');
  const [script, setScript] = useState('');
  const [programName, setProgramName] = useState('');
  const [keepProgram, setKeepProgram] = useState(false);
  // The device starts as a simple control panel; scripts and CLI are opt-in.
  const [simpleView, setSimpleView] = useState(true);
  const [editingScript, setEditingScript] = useState(false);
  const [checkedSource, setCheckedSource] = useState('');
  const [checkTag, setCheckTag] = useState<number | null>(null);
  const checkSerial = useRef(0);
  const [helpTopic, setHelpTopic] = useState<string | null>(null);
  const [eventView, setEventView] = useState(false);
  const commandInput = useRef<HTMLInputElement>(null);
  const log = useRef<HTMLDivElement>(null);
  const followLog = useRef(true);
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
  const checkEntry = checkTag === null ? null : [...data.entries].reverse().find(entry => entry.line === `check ${checkTag}`);
  const checkState = checkTag === null ? undefined : {
    status: checkEntry?.status ?? null,
    error: checkEntry?.error,
    position: checkEntry?.position,
    pending: !checkEntry || !!checkEntry.pending,
    stale: checkedSource !== script,
  };
  const helpEntry = helpTopic === null ? undefined : [...data.entries].reverse().find(entry => entry.line === helpLine(helpTopic));
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
  useEffect(() => {
    if (!editingScript && helpTopic === null) {
      commandInput.current?.focus();
    }
  }, [editingScript, helpTopic]);
  useLayoutEffect(() => {
    if (log.current && followLog.current) {
      log.current.scrollTop = log.current.scrollHeight;
    }
  });

  const run = (command: string) => {
    setEventView(false);
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
  const showTools = () => {
    setSimpleView(false);
    setEditingScript(false);
    setHelpTopic(null);
    setEventView(false);
  };
  const showEditor = () => {
    setSimpleView(false);
    setEditingScript(true);
    setHelpTopic(null);
    setEventView(false);
  };
  const showEvents = () => {
    setSimpleView(false);
    setEditingScript(false);
    setHelpTopic(null);
    setEventView(true);
  };

  const size = terminalSize(simpleView, editingScript);

  return (
    <Window title={`Сетевой модуль: ${data.title}`}
      width={size.width}
      height={size.height}>
      <Window.Content>
        <Stack vertical fill>
          <Stack.Item>
            <Section fitted>
              <Button icon="home" content="Обзор" selected={simpleView}
                onClick={() => setSimpleView(true)} />
              <Button icon="terminal" content="Инструменты"
                selected={!simpleView && !editingScript}
                onClick={showTools} />
              <Button icon="code" content="Редактор"
                selected={!simpleView && editingScript}
                onClick={showEditor} />
              <Button icon="project-diagram" content="Карта сети"
                onClick={() => act('open_space')} />
            </Section>
          </Stack.Item>
          {!simpleView && (
            <Stack.Item>
              <Section fitted>
                <Button icon="question-circle" content="Справка" selected={helpTopic !== null}
                  onClick={() => {
                    if (helpTopic === null) {
                      openHelp('');
                    } else {
                      setHelpTopic(null);
                    }
                  }} />
                <Button icon="search" content="Сервисы"
                  onClick={() => { setHelpTopic(null); run('services'); }} />
                <Button icon="plug" content="API"
                  onClick={() => { setHelpTopic(null); run('api'); }} />
                <Button icon="list" content="Команды"
                  onClick={() => { setHelpTopic(null); run('commands'); }} />
                <Button icon="tachometer-alt" content="Атмосфера"
                  onClick={() => { setHelpTopic(null); run('services -type atmos.alarm'); }} />
                <Button icon="tasks" content="Доставка"
                  onClick={() => { setHelpTopic(null); run('jobs'); }} />
                <Button icon="bell" content={`События (${data.events?.length ?? 0})`}
                  selected={eventView && helpTopic === null} onClick={() => {
                    setHelpTopic(null);
                    setEventView(!eventView);
                  }} />
                {!!data.programsEnabled && <Button icon="list" content="Программы"
                  onClick={() => { setHelpTopic(null); run('programs'); }} />}
              </Section>
            </Stack.Item>
          )}
          <Stack.Item grow>
            {simpleView ? (
              <NetdmHome
                title={data.title}
                connected={!!data.connectionReady}
                entries={data.entries}
                events={data.events?.length ?? 0}
                watches={data.watches?.length ?? 0}
                watchKeys={data.watches ?? []}
                onDiscover={() => run('services')}
                onAlarms={() => run('services -type atmos.alarm')}
                onMap={() => act('open_space')}
                onEvents={showEvents}
                onAdvanced={showTools}
                onInspect={command => { showTools(); run(command); }}
                onCommand={run}
              />
            ) : helpTopic !== null ? (
              <Help
                entry={helpEntry}
                topic={helpTopic}
                hasDraft={!!line.trim()}
                onTopic={openHelp}
                onExample={example => {
                  setLine(example);
                  setHistoryIndex(history.length);
                  setEditingScript(false);
                  setHelpTopic(null);
                }} />
            ) : eventView ? (
              <Section key="terminal-events" fill scrollable title="Доставленные события"
                buttons={<Button icon="list" content="Журнал" onClick={() => setEventView(false)} />}>
                <Box color="label" mb={1}>
                  Здесь отображаются только события, доставленные на ваш endpoint по активным подпискам.
                  Подписка не выполняет никаких действий с игровыми объектами.
                </Box>
                {(data.watches ?? []).length > 0 && (
                  <Box mb={1}>
                    <Box color="label" inline mr={1}>Подписки:</Box>
                    {(data.watches ?? []).filter(key => SERVICE_NAME.test(key)).map(key => (
                      <Button key={key} icon="times" content={key} tooltip="Отписаться"
                        onClick={() => run(`unwatch ${key}`)} />
                    ))}
                  </Box>
                )}
                {(data.events ?? []).length === 0 && (
                  <Box color="label">Событий пока нет. Найдите сервис и выполните watch.</Box>
                )}
                {(data.events ?? []).map(event => (
                  <Section key={event.delivery} title={`${event.instance} · ${event.schema}`}>
                    <Box color="label">Подписка: {event.key} · Доставка: {event.delivery}</Box>
                    <Box fontFamily="monospace" style={{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}>
                      {event.payload}{!!event.truncated && ' … (обрезано)'}
                    </Box>
                  </Section>
                ))}
              </Section>
            ) : (
              <Section
                key="terminal-log"
                fill
                scrollable
                scrollableRef={log}
                onScroll={() => {
                  const node = log.current;
                  if (node) {
                    followLog.current = node.scrollHeight - node.scrollTop - node.clientHeight < 32;
                  }
                }}
                title="Журнал терминала"
                buttons={<Button icon="eraser" tooltip="Очистить журнал" onClick={() => act('clear')} />}>
                {data.entries.length === 0 && <Box color="label">Введите команду или откройте справку.</Box>}
                {data.entries.map(entry => (
                  <EntryView key={entry.id} entry={entry} onCommand={run}
                    onDraft={command => { setLine(command); setEditingScript(false); setHelpTopic(null); }}
                    onStop={program => act('stop_program', { program })} />
                ))}
              </Section>
            )}
          </Stack.Item>
          {!simpleView && helpTopic === null && (editingScript ? (
            <Stack.Item>
              <Section
                title="Скрипт"
                buttons={
                  <>
                    {!script.trim() && (
                      <Dropdown
                        options={Object.keys(SCRIPT_EXAMPLES)}
                        selected="Пример"
                        onSelected={(key: keyof typeof SCRIPT_EXAMPLES) => setScript(SCRIPT_EXAMPLES[key])} />
                    )}
                    <Button
                      icon="play"
                      content="Запустить"
                      disabled={!canRunOnce}
                      tooltip="Однократный скрипт не допускает on/observe/every; запустите его как программу."
                      onClick={() => act('run_script', { source: script })}
                    />
                  </>
                }
              >
                <NetdmScriptIDE
                  key={loadedId}
                  source={script}
                  onChange={setScript}
                  limit={data.scriptLimit}
                  pool={completion}
                  check={checkState}
                  onCheck={() => {
                    const tag = ++checkSerial.current;
                    setCheckTag(tag);
                    setCheckedSource(script);
                    act('check_script', { source: script, name: SERVICE_NAME.test(programName) ? programName : 'draft', tag });
                  }}
                />
                {!!data.programsEnabled && (
                  <Stack mt={0.5}>
                    <Stack.Item grow>
                      <Input
                        fluid
                        maxLength={32}
                        placeholder="Имя программы"
                        value={programName}
                        onInput={(_event: unknown, value: string) => setProgramName(value)}
                      />
                    </Stack.Item>
                    <Stack.Item>
                      <Button
                        icon="play"
                        content="Запустить программу"
                        disabled={!canRun || !/^[a-zA-Z0-9._-]+$/.test(programName)}
                        onClick={() => act('start_program', { name: programName, source: script, keep: keepProgram })}
                      />
                    </Stack.Item>
                    {!!data.kept && (
                      <Stack.Item>
                        <Button.Checkbox
                          checked={keepProgram}
                          content="Хранить на устройстве"
                          tooltip="Программа записывается на устройство и запускается при каждом его подключении к сети."
                          onClick={() => setKeepProgram(!keepProgram)}
                        />
                      </Stack.Item>
                    )}
                  </Stack>
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
                      onClick={() => act('run_disk', { disk: disk.id, file: disk.file })}
                    />
                  </Box>
                ) : (
                  <Box color="label" mt={0.5}>Возьми Data Disk в руку для записи или чтения.</Box>
                )}
                {diskNotice && <Box mt={0.5}>{diskNotice}</Box>}
              </Section>
            </Stack.Item>
          ) : (
            <Stack.Item>
              <Stack>
                <Stack.Item grow>
                  <div className="Input Input--fluid Input--monospace">
                    <div className="Input__baseline" aria-hidden="true">.</div>
                    <input
                      ref={commandInput}
                      className="Input__input"
                      aria-label="Командная строка"
                      autoComplete="off"
                      spellCheck={false}
                      maxLength={data.limit}
                      placeholder="help · Tab дополнит · ↑↓ история"
                      value={line}
                      onChange={event => setLine(event.currentTarget.value)}
                      onKeyDown={event => {
                        if (event.nativeEvent.isComposing) {
                          return;
                        }
                        if (event.key === 'Tab') {
                          event.preventDefault();
                          setLine(current => tabComplete(current, completion));
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
                    <Box mt={0.5} color="label" fontSize="0.9em">
                      {usageHint ?? 'Tab — автодополнение · ↑↓ — история · Enter — выполнить'}
                    </Box>
                  </div>
                </Stack.Item>
                <Stack.Item>
                  <Button
                    icon="chevron-up"
                    tooltip="Предыдущая команда"
                    disabled={historyIndex === 0}
                    onClick={() => recall(historyIndex - 1)}
                  />
                  <Button
                    icon="chevron-down"
                    tooltip="Следующая команда или черновик"
                    disabled={historyIndex === history.length}
                    onClick={() => recall(historyIndex + 1)}
                  />
                  <Button icon="play" content="Выполнить" disabled={!line.trim()} onClick={() => send(line)} />
                </Stack.Item>
              </Stack>
            </Stack.Item>
          ))}
        </Stack>
      </Window.Content>
    </Window>
  );
};
