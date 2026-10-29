import { memo, useState } from 'react';

import { Box, Button, Icon } from '../../components';
import { THEME } from './types';
import { useNetrunBackend } from './useNetrunBackend';

/** Acquired grants become a transferable key; native ID rights stay in the dive session. */
export const AccessExport = memo(() => {
  const { act, data } = useNetrunBackend(['access_export', 'shard']);
  const [name, setName] = useState('Доступ.key');
  const [toShard, setToShard] = useState(false);
  const access = data.access_export;
  if (!access) { return null; }
  return (<details className="netrun-agent-details" data-net-access-export>
    <summary><Icon name="key" /> Ключ доступа</summary>
    <Box color={THEME.muted} fontSize="11px">Сохранить полученные взломом права в переносимый файл. Доступ ID остаётся в текущем погружении.</Box>
    <Box mt={0.5} fontSize="11px">Узлов: {access.node_count} · сетей: {access.network_count}</Box>
    <label className="netrun-field">Имя ключа<input value={name} maxLength={64} onChange={(event) => setName(event.target.value)} /></label>
    <label className="netrun-field">Сохранить ключ<select value={toShard && data.shard ? 'shard' : 'local'} onChange={(event) => setToShard(event.target.value === 'shard')}>
      <option value="local">Локальная память</option>
      {!!data.shard && <option value="shard">{data.shard.name}</option>}
                                                  </select>
    </label>
    <Button compact icon="file-export" content="Создать ключ" disabled={!access.can_export || !name.trim()}
      tooltip={access.reason || 'Сохранить права узлов и сетей в отдельном файле.'}
      onClick={() => act('access_export', { name: name.trim(), to_shard: !!data.shard && toShard })} />
    {!!access.reason && <Box color={THEME.muted} fontSize="11px" mt={0.5}>{access.reason}</Box>}
          </details>);
});
