import { KeyboardEvent, memo, useState } from 'react';

import { Box, Button, Icon, Input, Section } from '../../components';
import { FilePanel } from './FilePanel';
import { fileFormat, fileIcon } from './NodePanel';
import { LogLine, NetFile, NetrunData, THEME } from './types';
import { useFollowOutput } from './useFollowOutput';
import { useNetrunBackend as useBackend } from './useNetrunBackend';

const KIND_COLORS: Record<string, string> = {
  good: THEME.good,
  bad: THEME.bad,
  average: THEME.warn,
  label: THEME.text,
};

const LogLines = memo((props: { lines: LogLine[] }) => (<>{props.lines.map((line, index) => (
  <div key={index} style={{ color: KIND_COLORS[line.kind] || THEME.text, whiteSpace: 'pre-wrap' }}>
    {!!line.time && <span style={{ color: THEME.muted }}>{line.time} </span>}
    {line.text}
  </div>
))}
                                                        </>), (before, after) => before.lines.length === after.lines.length
  && before.lines.every((line, index) => line.text === after.lines[index].text
    && line.kind === after.lines[index].kind && line.time === after.lines[index].time));

const commonPrefix = (items: string[]): string => {
  if (!items.length) {
    return '';
  }
  let prefix = items[0];
  for (const it of items) {
    while (!it.toLowerCase().startsWith(prefix.toLowerCase())) {
      prefix = prefix.slice(0, -1);
      if (!prefix) {
        return '';
      }
    }
  }
  return prefix;
};

const ConsoleLogView = (props: { active?: boolean } = {}) => {
  const { act, data } = useBackend<NetrunData>(['log', 'cli', 'map', 'view', 'networks', 'window', 'selected', 'storage', 'shard']);
  const latestLine = data.log[data.log.length - 1];
  const output = useFollowOutput(`${data.log.length}:${latestLine?.time}:${latestLine?.text}`, props.active);
  const [value, setValue] = useState('');
  const [history, setHistory] = useState<string[]>([]);
  const [histIdx, setHistIdx] = useState<number | null>(null);
  const [draft, setDraft] = useState('');

  const entries = data.cli?.verbs ?? [];

  const submit = () => {
    const text = value.trim();
    if (!text) {
      return;
    }
    output.handleFollowLatest();
    act('cli', { text });
    setHistory((h) => {
      const next = h[h.length - 1] === text ? h : [...h, text];
      return next.slice(-20);
    });
    setHistIdx(null);
    setDraft('');
    setValue('');
  };

  const complete = () => {
    const verbs = entries.map((v) => v.id);
    const addresses = (data.map?.nodes ?? data.view?.nodes ?? []).map((n) => n.address);
    const codes = data.networks.map((n) => n.code);
    const tokens = value.split(' ');
    const last = tokens[tokens.length - 1];
    const verb = tokens[0].toLowerCase();
    const entry = entries.find((candidate) => candidate.id === verb);
    const registered = (entry?.completion_key ? data.cli?.completions?.[entry.completion_key] : undefined) ?? entry?.completions;
    const commands = (data.window?.commands ?? data.selected?.commands ?? []).map((c) => c.id);
    const files = [...data.storage.files, ...(data.shard?.files ?? [])].map((f) => f.name);
    const fallback = verb === 'run' ? commands
      : verb === 'help' ? [...verbs, ...commands]
      : verb === 'rm' ? files
      : verb === 'net' ? codes
      : ['sel', 'ping', 'open'].includes(verb) ? addresses
      : verb === 'breach' ? [...addresses, ...codes] : [];
    const pool = tokens.length <= 1 ? verbs : [...(registered ?? []), ...fallback];
    const hits = Array.from(new Set(pool)).filter((p) => p.toLowerCase().startsWith(last.toLowerCase()));
    if (!hits.length) {
      return;
    }
    const filled = hits.length === 1 ? hits[0] : commonPrefix(hits);
    if (!filled) {
      return;
    }
    tokens[tokens.length - 1] = filled;
    setValue(tokens.join(' ') + (hits.length === 1 && tokens.length <= 1 ? ' ' : ''));
  };

  const onKeyDown = (e: KeyboardEvent<HTMLInputElement>) => {
    switch (e.key) {
      case 'Enter':
        e.preventDefault();
        submit();
        break;
      case 'ArrowUp': {
        e.preventDefault();
        if (!history.length) {
          break;
        }
        if (histIdx === null) {
          setDraft(value);
        }
        const idx = histIdx === null ? history.length - 1 : Math.max(0, histIdx - 1);
        setHistIdx(idx);
        setValue(history[idx]);
        break;
      }
      case 'ArrowDown': {
        e.preventDefault();
        if (histIdx === null) {
          break;
        }
        const idx = histIdx + 1;
        if (idx >= history.length) {
          setHistIdx(null);
          setValue(draft);
        } else {
          setHistIdx(idx);
          setValue(history[idx]);
        }
        break;
      }
      case 'Tab':
        e.preventDefault();
        complete();
        break;
    }
  };

  return (
    <Box data-net-layout="console" style={{ background: THEME.bg, border: `1px solid ${THEME.line}`, display: 'flex', flexDirection: 'column', height: '100%', width: '100%', minHeight: 0, boxSizing: 'border-box' }}>
      <Box color={THEME.muted} p={0.5} fontSize="10px">
        <Button compact icon="question" content="help" onClick={() => act('cli', { text: 'help' })} />
        {' '}help &lt;команда&gt; — подробная справка · ↑/↓ история · Tab дополнение
      </Box>
      <div
        ref={output.scroller}
        onScroll={output.handleScroll}
        aria-label="Журнал терминала"
        style={{
          flex: '1 1 auto',
          minHeight: '70px',
          overflowY: 'auto',
          padding: '4px 6px',
          fontFamily: 'monospace',
          fontSize: '11px',
        }}
      >
        <LogLines lines={data.log} />
      </div>
      {!!output.unread && <Button compact icon="arrow-down" content="К новым сообщениям" onClick={output.handleFollowLatest} />}
      <input
        value={value}
        onChange={(e) => {
          setValue(e.target.value);
          setHistIdx(null);
        }}
        onKeyDown={onKeyDown}
        placeholder="help — список команд · ↑ история · Tab дополнение"
        spellCheck={false}
        style={{
          width: '100%',
          boxSizing: 'border-box',
          fontFamily: 'monospace',
          fontSize: '12px',
          color: THEME.text,
          background: THEME.panel,
          border: 'none',
          borderTop: `1px solid ${THEME.line}`,
          padding: '4px 6px',
          outline: 'none',
        }}
      />
    </Box>
  );
};

const StoragePanelView = () => {
  const { act, data } = useBackend<NetrunData>(['storage', 'shard', 'selected', 'host_actions']);
  const { storage, shard, selected } = data;
  const canUpload = !!selected?.files && selected.access >= 2;
  return (
    <Section title={`Память ${storage.used}/${storage.capacity}`} scrollable
      style={{ height: '100%', minHeight: '100%', boxSizing: 'border-box', overflowY: 'auto' }}>
      <div className="netrun-files-layout">
        <div className="netrun-files-catalog">
          <Box bold mb={1} color={THEME.text}>Локальные файлы</Box>
          <FileList files={storage.files} canUpload={canUpload} />
          {!!shard && (
            <Box mt={2}>
              <Box color={THEME.muted} mb={0.5}>
                <Icon name="sd-card" mr={1} />
                {shard.name} {shard.used}/{shard.capacity}
              </Box>
              <FileList files={shard.files} canUpload={canUpload} />
            </Box>
          )}
          {data.host_actions.length > 0 && (
            <Box mt={1}>
              {data.host_actions.map((a) => (
                <Button key={a.id} icon={a.icon} content={a.name} onClick={() => act(a.id)} />
              ))}
            </Box>
          )}
        </div>
        <div className="netrun-files-preview">
          <Box bold mb={1} color={THEME.text}>Просмотр и редактирование</Box>
          <FilePanel />
        </div>
      </div>
    </Section>
  );
};

const FileList = (props: { files: NetFile[]; canUpload: boolean }) => {
  const { act } = useBackend<NetrunData>([]);
  if (!props.files.length) {
    return <Box color={THEME.muted}>Пусто.</Box>;
  }
  return (
    <div data-net-files="local" style={{ maxHeight: '25vh', minHeight: 0, overflowY: 'auto' }}>
      {props.files.map((file) => (
        <Box
          key={file.uid}
          mb={0.5}
          p={0.5}
          style={{
            fontFamily: 'monospace',
            background: file.selected ? THEME.line : THEME.bg,
            border: `1px solid ${THEME.line}`,
            display: 'grid',
            gridTemplateColumns: 'minmax(0, 1fr) 78px',
            gap: '6px',
            alignItems: 'center',
            cursor: 'pointer',
          }}
          onClick={() => act('file_select', { uid: file.uid })}
        >
          <Box style={{ flex: 1, minWidth: 0, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
            <Icon name={fileIcon(file.kind)} mr={1} color={THEME.accent} />
            {file.name}
            <Box inline ml={1} color={THEME.muted} fontSize="9px">
              {fileFormat(file.name, file.kind)} · {file.size}
            </Box>
          </Box>
          <div data-net-file-actions="local" style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 24px)', gridAutoRows: '24px', gap: '3px' }}>
          <div>{file.kind === 'text' && (
            <Button compact icon="eye" tooltip="Открыть" onClick={(e) => { e.stopPropagation(); act('read', { uid: file.uid }); }} />
          )}
          </div>
          <div>{props.canUpload && (
            <Button compact icon="upload" tooltip="Загрузить на узел" onClick={(e) => { e.stopPropagation(); act('upload', { uid: file.uid }); }} />
          )}
          </div>
          <Button compact icon="trash" color="transparent" tooltip="Удалить" onClick={(e) => { e.stopPropagation(); act('delete_local', { uid: file.uid }); }} />
          </div>
        </Box>
      ))}
    </div>
  );
};

/** Карточка сущности: целостность и носитель */
const EntityPanelView = () => {
  const { data } = useBackend<NetrunData>(['entity']);
  const { entity } = data;
  if (!entity) {
    return null;
  }
  const ratio = entity.integrity / entity.max_integrity;
  return (
    <Box
      p={1}
      mb={1}
      style={{ background: THEME.bg, border: `1px solid #d05090`, fontFamily: 'monospace' }}
    >
      <Box color="#d05090" bold>
        {entity.name}
        {entity.diving ? ' · погружение' : ''}
      </Box>
      <Box color={THEME.muted} fontSize="11px">
        Носитель: {entity.host_name || '—'} {entity.host || ''}
      </Box>
      <Box mt={0.5} style={{ height: '6px', background: THEME.line }}>
        <Box
          style={{
            height: '6px',
            width: `${Math.max(0, ratio * 100)}%`,
            background: ratio > 0.5 ? THEME.good : ratio > 0.25 ? THEME.warn : THEME.bad,
          }}
        />
      </Box>
      <Box fontSize="11px" color={THEME.muted}>
        Целостность {entity.integrity}/{entity.max_integrity}
      </Box>
    </Box>
  );
};

/** Канал #noosphere - общий чат сущностей и консолей (NTNRC) */
const NetChatView = (props: { active?: boolean } = {}) => {
  const { act, data } = useBackend<NetrunData>(['chat', 'uplink', 'entity']);
  const { chat, uplink, entity } = data;
  const output = useFollowOutput(`${chat.messages.length}:${chat.messages[chat.messages.length - 1]}`, props.active);
  return (
    <Box style={{ background: THEME.bg, border: `1px solid ${THEME.line}`, display: 'flex', flexDirection: 'column', height: '100%', width: '100%', minHeight: 0 }}>
      <div
        ref={output.scroller}
        onScroll={output.handleScroll}
        aria-label="Сообщения noosphere"
        style={{
          flex: '1 1 auto',
          minHeight: '70px',
          overflowY: 'auto',
          padding: '4px 6px',
          fontFamily: 'monospace',
          fontSize: '11px',
        }}
      >
        {chat.messages.map((line, i) => (
          <div
            key={i}
            style={{
              color: line.includes(' -!- ') ? THEME.muted : THEME.text,
              whiteSpace: 'pre-wrap',
            }}
          >
            {line}
          </div>
        ))}
      </div>
      {!!output.unread && <Button compact icon="arrow-down" content="К новым сообщениям" onClick={output.handleFollowLatest} />}
      <Box style={{ display: 'flex' }}>
        {!entity && (
          <Input
            width="110px"
            value={chat.handle}
            onChange={(_e, value) => act('set_handle', { handle: value })}
            style={{ fontFamily: 'monospace', background: THEME.panel }}
          />
        )}
        <Box style={{ flexGrow: 1 }}>
          <Input
            fluid
            selfClear
            disabled={!uplink}
            placeholder={uplink ? `${chat.handle} в #noosphere` : 'Нет связи с NTnet'}
            onEnter={(_e, value) => { output.handleFollowLatest(); act('chat_send', { text: value }); }}
            style={{ fontFamily: 'monospace', background: THEME.panel }}
          />
        </Box>
      </Box>
    </Box>
  );
};

export const ConsoleLog = memo(ConsoleLogView);

export const StoragePanel = memo(StoragePanelView);

export const EntityPanel = memo(EntityPanelView);

export const NetChat = memo(NetChatView);
