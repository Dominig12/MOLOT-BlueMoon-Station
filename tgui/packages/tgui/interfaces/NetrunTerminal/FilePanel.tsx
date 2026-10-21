import { useEffect, useState } from 'react';

import { useBackend } from '../../backend';
import { Box, Button, Input } from '../../components';
import { NetrunData, THEME } from './types';

export const FilePanel = () => {
  const { data } = useBackend<NetrunData>();
  const [creating, setCreating] = useState(false);
  return (
    <Box mt={1}>
      <Button compact icon="file-circle-plus" content="Новый текстовый файл" selected={creating} onClick={() => setCreating(!creating)} />
      {creating ? (
        <FileEditor key="new" onCreated={() => setCreating(false)} />
      ) : data.file ? (
        <FileEditor key={data.file.uid} />
      ) : (
        <Box mt={0.5} color={THEME.muted} fontSize="11px">Выберите файл для просмотра, редактирования или печати.</Box>
      )}
    </Box>
  );
};

const FileEditor = (props: { onCreated?: () => void }) => {
  const { act, data } = useBackend<NetrunData>();
  const file = props.onCreated ? null : data.file;
  const [name, setName] = useState(file?.name ?? 'note.txt');
  const [content, setContent] = useState(file?.content ?? '');
  const [toShard, setToShard] = useState(file?.source === 'shard');
  const [submitted, setSubmitted] = useState<{
    previousUid: string | null;
    name: string;
    content: string;
  } | null>(null);
  useEffect(() => {
    // A failed request leaves the draft mounted. Only a newly created file
    // with the submitted contents acknowledges creation; polling cannot erase
    // text typed since the request was sent.
    if (props.onCreated && submitted && data.file?.kind === 'text'
      && data.file.uid !== submitted.previousUid
      && data.file.content === submitted.content
      && name === submitted.name && content === submitted.content) {
      props.onCreated();
    }
  }, [data.file, submitted, name, content, props.onCreated]);
  return (
    <Box mt={0.5} p={0.5} style={{ background: THEME.bg }}>
      <Input fluid value={name} onInput={(_event, value) => setName(value)} />
      {file && (
        <Box mt={0.5} color={THEME.muted} fontSize="11px">
          {file.source === 'shard' ? 'Шард' : 'Локальная память'} · {file.kind} · {file.size}
        </Box>
      )}
      {file?.kind === 'photo' && file.image && (
        <img src={file.image} alt={file.name} style={{ display: 'block', maxWidth: '100%', maxHeight: '260px', marginTop: '6px', objectFit: 'contain' }} />
      )}
      {(!file || file.kind === 'text') ? (
        <textarea
          value={content}
          onChange={(event) => setContent(event.target.value)}
          rows={6}
          maxLength={10000}
          spellCheck={false}
          style={{ width: '100%', boxSizing: 'border-box', resize: 'vertical', background: THEME.panel, color: THEME.text, border: `1px solid ${THEME.line}`, marginTop: '6px', fontFamily: 'monospace' }}
        />
      ) : file?.preview ? (
        <Box mt={0.5} style={{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}>{file.preview}</Box>
      ) : null}
      <Box mt={0.5} style={{ display: 'flex', flexWrap: 'wrap', gap: '4px', alignItems: 'center' }}>
        {!file ? (
          <>
            {data.shard && <Button compact icon="sd-card" content="На шард" selected={toShard} onClick={() => setToShard(!toShard)} />}
            <Button compact icon="save" content="Создать" disabled={!name.trim()} onClick={() => {
              setSubmitted({ previousUid: data.file?.uid ?? null, name, content });
              act('file_new', { name, content, to_shard: toShard });
            }} />
          </>
        ) : (
          <>
            <Button compact icon="signature" content="Переименовать" disabled={!name.trim() || name === file.name} onClick={() => act('file_rename', { uid: file.uid, name })} />
            {file.kind === 'text' && <Button compact icon="save" content="Сохранить" disabled={content === file.content} onClick={() => act('file_edit', { uid: file.uid, content })} />}
            {data.shard && (
              <>
                <Button compact icon="copy" tooltip={file.source === 'shard' ? 'Скопировать в память' : 'Скопировать на шард'} onClick={() => act('file_copy', { uid: file.uid, to_shard: file.source !== 'shard' })} />
                <Button compact icon="arrow-right-arrow-left" tooltip={file.source === 'shard' ? 'Переместить в память' : 'Переместить на шард'} onClick={() => act('file_move', { uid: file.uid, to_shard: file.source !== 'shard' })} />
              </>
            )}
          </>
        )}
      </Box>
      {!file && submitted && (
        <Box mt={0.5} color={THEME.muted} fontSize="11px">
          Запрос отправлен. До подтверждения создания текст остаётся в редакторе; результат — в журнале.
        </Box>
      )}
    </Box>
  );
};
