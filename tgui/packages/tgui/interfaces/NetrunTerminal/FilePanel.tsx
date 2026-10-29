import { memo, useEffect, useRef, useState } from 'react';

import { Box, Button, Input } from '../../components';
import { AgentBuilderPanel } from './AgentBuilderPanel';
import { AgentsPanel } from './AgentsPanel';
import { NetFile, NetrunData, THEME } from './types';
import { useNetrunBackend as useBackend } from './useNetrunBackend';

/** Human labels for file kinds that are not self-explanatory in the editor header. */
const FILE_KIND_LABELS: Record<string, string> = {
  bot: 'агент',
};

const FilePanelView = () => {
  const { data } = useBackend<NetrunData>(['file']);
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
      <AgentsPanel />
    </Box>
  );
};

/** An agent program leaves memory as a running process at the launch site the server
 * resolves: the own entity's node, otherwise the node selected on the map. */
const BotLaunch = (props: { file: NetFile }) => {
  const { act, data } = useBackend<NetrunData>(['entity', 'selected']);
  const host = data.entity?.host;
  const site = host
    ? `Старт: узел вашей сущности ${data.entity?.host_name || ''} ${host}.`
    : data.selected
      ? `Старт: выбранный на карте узел ${data.selected.name} ${data.selected.address} (нужны доступ ПОЛЬЗОВАТЕЛЯ и маршрут).`
      : 'Старт: выберите узел на карте с доступом ПОЛЬЗОВАТЕЛЯ и маршрутом.';
  return (
    <Box mt={0.5} data-net-bot-launch={props.file.uid}>
      <Button compact icon="robot" content="Запустить агента" onClick={() => act('bot_launch', { uid: props.file.uid })} />
      <Box mt={0.5} color={THEME.muted} fontSize="11px">
        {site} Файл переходит в агента и возвращается при отзыве.
      </Box>
    </Box>
  );
};

const FileTransfer = ({ file }: { file: NonNullable<NetrunData['file']> }) => {
  const { act, data } = useBackend<NetrunData>(['shard', 'storage']);
  if (file.source === 'shard') {
    if (!file.can_import) { return null; }
    const full = file.size > (data.storage?.capacity ?? 0) - (data.storage?.used ?? 0);
    return (<>
      <Button compact icon="download" content="Копировать в память" disabled={full}
        tooltip={full ? 'Недостаточно места в локальной памяти.' : 'Сохранить локальную копию; исходный файл остаётся на шарде.'}
        onClick={() => act('file_import', { uid: file.uid, move: false })} />
      <Button compact icon="arrow-right-arrow-left" content="Перенести в память" disabled={full}
        tooltip={full ? 'Недостаточно места в локальной памяти.' : 'Переместить файл с шарда в локальную память.'}
        onClick={() => act('file_import', { uid: file.uid, move: true })} />
            </>);
  }
  return data.shard ? (<>
    <Button compact icon="copy" tooltip="Скопировать на шард" onClick={() => act('file_copy', { uid: file.uid, to_shard: true })} />
    <Button compact icon="arrow-right-arrow-left" tooltip="Переместить на шард" onClick={() => act('file_move', { uid: file.uid, to_shard: true })} />
                       </>) : null;
};

const FileEditor = (props: { onCreated?: () => void }) => {
  const { act, data } = useBackend<NetrunData>(['file', 'shard']);
  const file = props.onCreated ? null : data.file;
  const [name, setName] = useState(file?.name ?? 'note.txt');
  const [content, setContent] = useState(file?.content ?? '');
  const confirmed = useRef({ name: file?.name ?? 'note.txt', content: file?.content ?? '' });
  const [toShard, setToShard] = useState(file?.source === 'shard');
  const [submitted, setSubmitted] = useState<{
    previousUid: string | null;
    name: string;
    content: string;
  } | null>(null);
  useEffect(() => {
    if (!file) { return; }
    const before = confirmed.current, next = { name: file.name, content: file.content ?? '' };
    // A clean field follows server pushes. A dirty field keeps the draft,
    // including text entered after saving but before its receipt arrived.
    setName((draft) => draft === before.name ? next.name : draft);
    setContent((draft) => draft === before.content ? next.content : draft);
    confirmed.current = next;
  }, [file?.uid, file?.name, file?.content]);
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
      {!!file && (
        <Box mt={0.5} color={THEME.muted} fontSize="11px">
          {file.source === 'shard' ? 'Шард' : 'Локальная память'} · {FILE_KIND_LABELS[file.kind] || file.kind} · {file.size}
        </Box>
      )}
      {file?.kind === 'photo' && !!file.image && (
        <div
          style={{
            marginTop: '6px',
            maxWidth: '100%',
            maxHeight: '260px',
            // Сохраняем пропорции кадра: контейнер не превышает натуральный размер картинки.
            aspectRatio: file.width && file.height ? `${file.width} / ${file.height}` : undefined,
            width: file.width ? `${file.width}px` : 'auto',
            overflow: 'hidden',
            background: THEME.bg,
          }}
        >
          <img
            src={file.image}
            alt={file.name}
            style={{
              display: 'block',
              width: '100%',
              height: '100%',
              // Картинка растягивается по размеру рамки, а не повторяется плиткой.
              objectFit: 'contain',
              backgroundRepeat: 'no-repeat',
              imageRendering: 'pixelated',
            }}
          />
        </div>
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
            {!!data.shard && <Button compact icon="sd-card" content="На шард" selected={toShard} onClick={() => setToShard(!toShard)} />}
            <Button compact icon="save" content="Создать" disabled={!name.trim()} onClick={() => {
              setSubmitted({ previousUid: data.file?.uid ?? null, name, content });
              act('file_new', { name, content, to_shard: toShard });
            }} />
          </>
        ) : (
          <>
            <Button compact icon="signature" content="Переименовать" disabled={!name.trim() || name === file.name} onClick={() => act('file_rename', { uid: file.uid, name })} />
            {file.kind === 'text' && <Button compact icon="save" content="Сохранить" disabled={content === file.content} onClick={() => act('file_edit', { uid: file.uid, content })} />}
            <FileTransfer file={file} />
          </>
        )}
      </Box>
      {file?.kind === 'bot' && <BotLaunch file={file} />}
      {!!file?.agent_builder && <AgentBuilderPanel key={file.uid} builder={file.agent_builder} />}
      {!file && !!submitted && (
        <Box mt={0.5} color={THEME.muted} fontSize="11px">
          Запрос отправлен. До подтверждения создания текст остаётся в редакторе; результат — в журнале.
        </Box>
      )}
    </Box>
  );
};

export const FilePanel = memo(FilePanelView);
