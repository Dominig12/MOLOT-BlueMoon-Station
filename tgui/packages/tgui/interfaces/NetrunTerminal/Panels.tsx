import { useEffect, useRef } from 'react';

import { useBackend } from '../../backend';
import { Box, Button, Icon, Input, Section } from '../../components';
import { fileIcon } from './NodePanel';
import { NetFile, NetrunData, THEME } from './types';

const KIND_COLORS: Record<string, string> = {
  good: THEME.good,
  bad: THEME.bad,
  average: THEME.warn,
  label: THEME.text,
};

export const ConsoleLog = () => {
  const { act, data } = useBackend<NetrunData>();
  const scroller = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (scroller.current) {
      scroller.current.scrollTop = scroller.current.scrollHeight;
    }
  }, [data.log.length]);
  return (
    <Box style={{ background: THEME.bg, border: `1px solid ${THEME.line}` }}>
      <div
        ref={scroller}
        style={{
          height: '120px',
          overflowY: 'auto',
          padding: '4px 6px',
          fontFamily: 'monospace',
          fontSize: '11px',
        }}
      >
        {data.log.map((line, i) => (
          <div key={i} style={{ color: KIND_COLORS[line.kind] || THEME.text, whiteSpace: 'pre-wrap' }}>
            {line.time && <span style={{ color: THEME.muted }}>{line.time} </span>}
            {line.text}
          </div>
        ))}
      </div>
      <Input
        fluid
        selfClear
        placeholder="help — список команд"
        onEnter={(_e, value) => act('cli', { text: value })}
        style={{ fontFamily: 'monospace', background: THEME.panel }}
      />
    </Box>
  );
};

export const StoragePanel = () => {
  const { act, data } = useBackend<NetrunData>();
  const { storage, shard, selected } = data;
  const canUpload = !!selected?.files && selected.access >= 2;
  return (
    <Section title={`Память ${storage.used}/${storage.capacity}`} fill scrollable>
      <FileList files={storage.files} canUpload={canUpload} />
      {shard && (
        <Box mt={1}>
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
    </Section>
  );
};

const FileList = (props: { files: NetFile[]; canUpload: boolean }) => {
  const { act } = useBackend<NetrunData>();
  if (!props.files.length) {
    return <Box color={THEME.muted}>Пусто.</Box>;
  }
  return (
    <>
      {props.files.map((file) => (
        <Box key={file.uid} mb={0.5} style={{ fontFamily: 'monospace' }}>
          <Icon name={fileIcon(file.kind)} mr={1} />
          {file.name}
          <Box inline style={{ float: 'right' }}>
            {file.kind === 'text' && (
              <Button compact icon="eye" onClick={() => act('read', { uid: file.uid })} />
            )}
            {props.canUpload && (
              <Button compact icon="upload" tooltip="Загрузить на узел" onClick={() => act('upload', { uid: file.uid })} />
            )}
            <Button compact icon="trash" tooltip="Удалить" onClick={() => act('delete_local', { uid: file.uid })} />
          </Box>
        </Box>
      ))}
    </>
  );
};

/** Карточка сущности: целостность и носитель */
export const EntityPanel = () => {
  const { data } = useBackend<NetrunData>();
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
