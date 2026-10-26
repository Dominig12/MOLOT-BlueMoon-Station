import { memo } from 'react';

import { Box, Button, Icon, Input, Section } from '../../components';
import { FilePanel } from './FilePanel';
import { fileFormat, fileIcon } from './NodePanel';
import { NetFile, NetrunData, THEME } from './types';
import { useFollowOutput } from './useFollowOutput';
import { useNetrunBackend as useBackend } from './useNetrunBackend';

const StoragePanelView = () => {
  const { data } = useBackend<NetrunData>(['storage', 'shard', 'selected']);
  const { storage, shard, selected } = data;
  const canUpload = !!selected?.files && selected.access >= 2;
  return (
    <Section title={`Память ${storage.used}/${storage.capacity}`} scrollable
      style={{ height: '100%', minHeight: '100%', boxSizing: 'border-box', overflowY: 'auto' }}>
      <div className="netrun-files-layout">
        <div className="netrun-files-catalog">
          <Box bold mb={1} color={THEME.text}>Локальные файлы</Box>
          <FileList files={storage.files} canUpload={canUpload} source="local" />
          {!!shard && (
            <Box mt={2}>
              <Box color={THEME.muted} mb={0.5}>
                <Icon name="sd-card" mr={1} />
                {shard.name} {shard.used}/{shard.capacity}
              </Box>
              <FileList files={shard.files} canUpload={canUpload} source="shard" />
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

const FileList = (props: { files: NetFile[]; canUpload: boolean; source: 'local' | 'shard' }) => {
  const { act } = useBackend<NetrunData>([]);
  if (!props.files.length) {
    return <Box color={THEME.muted}>Пусто.</Box>;
  }
  return (
    <div data-net-files={props.source} style={{ maxHeight: '25vh', minHeight: 0, overflowY: 'auto' }}>
      {props.files.map((file) => (
        <Box
          key={file.uid}
          data-net-file-row={props.source}
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
          <div className="netrun-file-actions" data-net-file-actions={props.source}
            style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 24px)', gridAutoRows: '24px', gap: '3px' }}>
            {file.kind === 'text' && (
              <Button compact icon="eye" tooltip="Открыть" style={{ gridColumn: 1 }}
                onClick={(e) => { e.stopPropagation(); act('read', { uid: file.uid }); }} />
            )}
            {props.canUpload && (
              <Button compact icon="upload" tooltip="Загрузить на узел" style={{ gridColumn: 2 }}
                onClick={(e) => { e.stopPropagation(); act('upload', { uid: file.uid }); }} />
            )}
            <Button compact icon="trash" color="transparent" tooltip="Удалить" style={{ gridColumn: 3 }}
              onClick={(e) => { e.stopPropagation(); act('delete_local', { uid: file.uid }); }} />
          </div>
        </Box>
      ))}
    </div>
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

export { ConsoleLog } from './TerminalConsole';

export const StoragePanel = memo(StoragePanelView);

export { EntityPanel } from './EntityProfile';

export const NetChat = memo(NetChatView);
