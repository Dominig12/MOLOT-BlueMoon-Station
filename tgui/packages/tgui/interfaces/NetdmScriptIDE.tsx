import { KeyboardEvent, useMemo, useRef, useState } from 'react';

import { Box, Button, NoticeBox, Section, Stack, TextArea } from '../components';
import { SHELL_COMMANDS, ShellDynamicPool } from './netdmShell';

/** Local hints never execute a script. Authoritative validation is performed by network.shell/check. */
export type ScriptCheck = {
  status: string | null;
  error?: string | null;
  position?: number | null;
  pending?: boolean;
  stale?: boolean;
};

const ROOT_WORDS = ['observe', 'on events -key ', 'every 10', 'if ', 'wait', 'end', '$state = ',
  ...SHELL_COMMANDS.map(command => command.name)];

const OBSERVE_OPTIONS = ['-key', '-projection', '-mode', '-pending'];
const KEY_PATTERN = /(?:^|\n)observe\s+\S+\s+-key\s+([a-zA-Z0-9._-]+)/g;

export const scriptLocation = (source: string, position: number): { line: number; column: number } => {
  const before = source.slice(0, Math.max(0, Math.min(source.length, position)));
  const lines = before.split('\n');
  return { line: lines.length, column: lines[lines.length - 1].length + 1 };
};

export const scriptOutline = (source: string): { line: number; label: string }[] =>
  source.split('\n').flatMap((raw, index) => {
    const value = raw.trim();
    if (/^(observe|on|every|if|wait)\s/.test(value) || value === 'wait') {
      return [{ line: index + 1, label: value.slice(0, 72) }];
    }
    return [];
  }).slice(0, 20);

/** Completions are computed from local text and already-discovered services, never the hidden registry. */
export const scriptSuggestions = (
  source: string,
  offset: number,
  pool: ShellDynamicPool = {},
): string[] => {
  const before = source.slice(0, Math.max(0, Math.min(source.length, offset)));
  const line = before.split('\n').pop() ?? '';
  const segment = line.split('|').pop() ?? '';
  const clean = segment.trimStart();
  const parts = clean.split(/\s+/);
  const prefix = /\s$/.test(segment) ? '' : parts[parts.length - 1] ?? '';
  const first = clean.length === 0 || (!/\s/.test(clean) && !/\s$/.test(segment));
  const observing = clean.startsWith('observe ');
  const root = first ? ROOT_WORDS : [];
  const keys = [...source.matchAll(KEY_PATTERN)].map(match => match[1]);
  const option = observing && prefix.startsWith('-') ? OBSERVE_OPTIONS : [];
  const service = (observing || clean.startsWith('invoke ') || clean.startsWith('watch ') ||
    clean.startsWith('route ')) ? pool.instances ?? [] : [];
  const eventKeys = (line.includes('events') && (parts[parts.length - 2] === '-key'))
    ? keys : [];
  return [...new Set([...root, ...option, ...service, ...eventKeys])]
    .filter(word => word.startsWith(prefix) && word !== prefix)
    .sort((a, b) => a.localeCompare(b))
    .slice(0, 8);
};

/** Substitute only the token before the caret; nothing is ever sent to the network. */
export const insertCompletion = (
  source: string,
  offset: number,
  choice: string,
): { source: string; caret: number } => {
  const cursor = Math.max(0, Math.min(offset, source.length));
  const prior = source.slice(0, cursor);
  const match = prior.match(/[^\s|]*$/);
  const length = match?.[0].length ?? 0;
  const insert = choice + (choice.endsWith(' ') ? '' : ' ');
  const value = prior.slice(0, cursor - length) + insert + source.slice(cursor);
  return { source: value, caret: cursor - length + insert.length };
};

type Props = {
  source: string;
  onChange: (source: string) => void;
  limit: number;
  pool: ShellDynamicPool;
  check?: ScriptCheck;
  onCheck: () => void;
};

export const NetdmScriptIDE = ({ source, onChange, limit, pool, check, onCheck }: Props) => {
  const caret = useRef(source.length);
  const editor = useRef<TextArea | null>(null);
  const [preview, setPreview] = useState(false);
  const lines = source.split('\n');
  const outline = useMemo(() => scriptOutline(source), [source]);
  const candidates = useMemo(() => scriptSuggestions(source, caret.current, pool), [source, pool]);
  const issue = check?.position === null || check?.position === undefined ? null
    : scriptLocation(source, check.position);

  const applyCompletion = (current: string, position: number, choice: string) => {
    const next = insertCompletion(current, position, choice);
    if (next.source.length > limit) {
      return;
    }
    const input = editor.current?.textareaRef.current;
    if (input) {
      // TextArea owns the DOM while it is editing: update its live input as well
      // as React state, otherwise mouse completion is invisible until blur.
      input.value = next.source;
      input.setSelectionRange(next.caret, next.caret);
      input.focus();
    }
    caret.current = next.caret;
    onChange(next.source);
  };
  const choose = (choice: string) => {
    const input = editor.current?.textareaRef.current;
    applyCompletion(input?.value ?? source, input?.selectionStart ?? caret.current, choice);
  };

  return (
    <Section
      title="IDE · Network Shell"
      buttons={
        <>
          <Button icon="check-circle" content="Проверить код" onClick={onCheck}
            disabled={!source.trim() || source.length > limit || !!check?.pending} />
          <Button icon="eye" selected={preview} onClick={() => setPreview(!preview)}
            tooltip="Обзор структуры программы" content={preview ? 'Редактор' : 'Структура'} />
        </>
      }>
      <Stack>
        <Stack.Item grow basis={0}>
          <Box color="label" mb={0.5}>Код исполняется на устройстве. Проверка не запускает команды и не меняет сеть.</Box>
          <Stack>
            <Stack.Item>
              <Box as="pre" color="label" m={0} style={{
                textAlign: 'right', userSelect: 'none', lineHeight: '1.46em',
                fontFamily: 'monospace', paddingTop: '4px', minWidth: '2.1em',
              }}>
                {lines.map((_text, index) => String(index + 1)).join('\n')}
              </Box>
            </Stack.Item>
            <Stack.Item grow basis={0}>
              <TextArea
                ref={editor}
                fluid
                scrollbar
                height={14}
                maxLength={limit}
                dontUseTabForIndent
                placeholder={'observe atmos.sensor -key air\non events -key air | where pressureKPa -gt 130\n$event | count'}
                value={source}
                onInput={(event: { target: HTMLTextAreaElement }, value: string) => {
                  caret.current = event.target.selectionStart ?? value.length;
                  onChange(value);
                }}
                onChange={(event: { target: HTMLTextAreaElement }, value: string) => {
                  caret.current = event.target.selectionStart ?? value.length;
                  onChange(value);
                }}
                onKeyDown={(event: KeyboardEvent<HTMLTextAreaElement>) => {
                  caret.current = event.currentTarget.selectionStart;
                  if (event.key === 'Tab') {
                    event.preventDefault();
                    const suggestions = scriptSuggestions(event.currentTarget.value, caret.current, pool);
                    if (suggestions.length === 1) {
                      applyCompletion(event.currentTarget.value, caret.current, suggestions[0]);
                    } else {
                      applyCompletion(event.currentTarget.value, caret.current, '  ');
                    }
                  }
                }}
              />
            </Stack.Item>
          </Stack>
          <Box color="label" mt={0.5}>{source.length}/{limit} символов · {lines.length} строк</Box>
          {candidates.length > 0 && (
            <Box mt={0.5}>
              <Box inline color="label" mr={0.5}>Подсказки:</Box>
              {candidates.map(candidate => (
                <Button key={candidate} content={candidate} onClick={() => choose(candidate)} />
              ))}
            </Box>
          )}
        </Stack.Item>
        {preview && (
          <Stack.Item basis="33%">
            <Section title="Структура">
              {outline.length === 0
                ? <Box color="label">Декларации, правила и ожидания появятся здесь.</Box>
                : outline.map(item => (
                  <Box key={item.line} mb={0.5}>
                    <Box inline color="label" mr={0.5}>{item.line}</Box>
                    <Box inline>{item.label}</Box>
                  </Box>
                ))}
            </Section>
          </Stack.Item>
        )}
      </Stack>
      {!!check?.pending && <NoticeBox info mt={0.5}>Исходник отправлен на проверку через network.shell.</NoticeBox>}
      {!!check?.stale && <Box color="label" mt={0.5}>Исходник изменён после проверки — проверьте новую версию.</Box>}
      {!check?.stale && check?.status === 'valid' && (
        <NoticeBox success mt={0.5}>
          Компиляция успешна. Сетевые команды не выполнялись.
        </NoticeBox>
      )}
      {!check?.stale && !!check?.status && check.status !== 'valid' && !check.pending && (
        <NoticeBox danger mt={0.5}>
          {check.error || check.status}
          {issue && ` · строка ${issue.line}, столбец ${issue.column}`}
        </NoticeBox>
      )}
    </Section>
  );
};
