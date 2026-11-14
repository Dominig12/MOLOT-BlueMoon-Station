import { BooleanLike } from 'common/react';
import { useEffect, useState } from 'react';

import { useBackend } from '../backend';
import { Box, Button, Input, NoticeBox, Section, Stack, Table, TextArea } from '../components';
import { Window } from '../layouts';

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

type Data = {
  title: string;
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

const Records = (props: { records: Field[][]; onStop?: (id: string) => void }) => {
  const { records, onStop } = props;
  const columns = columnsOf(records);
  return (
    <Table>
      <Table.Row header>
        {columns.map((name) => (
          <Table.Cell key={name}>{name}</Table.Cell>
        ))}
        {onStop && <Table.Cell />}
      </Table.Row>
      {records.map((record, index) => {
        const id = record.find((field) => field.name === 'program')?.value;
        return (
          <Table.Row key={index}>
            {columns.map((name) => (
              <Table.Cell key={name}>{record.find((field) => field.name === name)?.value ?? ''}</Table.Cell>
            ))}
            {onStop && <Table.Cell>{id && <Button icon="stop" content="Остановить" onClick={() => onStop(id)} />}</Table.Cell>}
          </Table.Row>
        );
      })}
    </Table>
  );
};

const EntryView = (props: { entry: Entry; onStop: (id: string) => void }) => {
  const { entry, onStop } = props;
  const failed = !entry.pending && !['ok', 'started', 'stopped'].includes(entry.status || '');
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
      {entry.records.length > 0 && <Records records={entry.records} onStop={entry.line === 'programs' ? onStop : undefined} />}
    </Box>
  );
};

export const NetdmTerminal = () => {
  const { act, data } = useBackend<Data>();
  const [line, setLine] = useState('');
  const [script, setScript] = useState('');
  const [programName, setProgramName] = useState('');
  const [keepProgram, setKeepProgram] = useState(false);
  const [editingScript, setEditingScript] = useState(false);
  const { disk, diskNotice, loadedScript } = data;
  const loadedId = loadedScript?.id;
  const loadedSource = loadedScript?.source;
  useEffect(() => {
    if (loadedSource !== undefined) {
      setScript(loadedSource);
    }
  }, [loadedId, loadedSource]);
  const canRun = !!script.trim() && script.length <= data.scriptLimit;
  const send = (text: string) => {
    const trimmed = text.trim();
    if (trimmed.length > 0 && trimmed.length <= data.limit) {
      act('run', { line: trimmed });
      setLine('');
    }
  };
  return (
    <Window title={`Сетевой модуль: ${data.title}`} width={640} height={520}>
      <Window.Content>
        <Stack vertical fill>
          <Stack.Item grow>
            <Section
              fill
              scrollable
              title="Терминал"
              buttons={
                <>
                  <Button icon="code" content="Скрипт" selected={editingScript} onClick={() => setEditingScript(!editingScript)} />
                  <Button icon="list" content="Программы" onClick={() => act('list_programs')} />
                  <Button icon="eraser" content="Очистить" onClick={() => act('clear')} />
                </>
              }
            >
              {data.entries.length === 0 && (
                <Box color="label">
                  Команды: services, links, self, trace, затем where, select, sort, first, last, count; действие — invoke.
                </Box>
              )}
              {data.entries.map((entry) => (
                <EntryView key={entry.id} entry={entry} onStop={(program) => act('stop_program', { program })} />
              ))}
            </Section>
          </Stack.Item>
          {editingScript ? (
            <Stack.Item>
              <Section
                title="Скрипт"
                buttons={
                  <Button
                    icon="play"
                    content="Запустить"
                    disabled={!canRun}
                    onClick={() => act('run_script', { source: script })}
                  />
                }
              >
                <Box color="label" mb={0.5}>Условие if выполняет блок, если конвейер вернул хотя бы одну запись. Закройте блок командой end.</Box>
                <TextArea
                  key={loadedId}
                  fluid
                  scrollbar
                  height={7}
                  maxLength={data.scriptLimit}
                  placeholder={'if links | where state -eq up\n  services -type research.server | sort hops | first 1\nend'}
                  value={script}
                  onInput={(_event: unknown, value: string) => setScript(value)}
                  onChange={(_event: unknown, value: string) => setScript(value)}
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
                  <Input
                    fluid
                    autoFocus
                    maxLength={data.limit}
                    placeholder="services -type research.server | sort hops | first 3"
                    value={line}
                    onInput={(_event: unknown, value: string) => setLine(value)}
                    onEnter={(_event: unknown, value: string) => send(value)}
                  />
                </Stack.Item>
                <Stack.Item>
                  <Button icon="play" content="Выполнить" onClick={() => send(line)} />
                </Stack.Item>
              </Stack>
            </Stack.Item>
          )}
        </Stack>
      </Window.Content>
    </Window>
  );
};
