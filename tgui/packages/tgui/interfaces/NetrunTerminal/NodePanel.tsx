import { useBackend } from '../../backend';
import { Box, Button, Icon, LabeledList, Section } from '../../components';
import { AutoBreachButton } from './AutoBreachButton';
import { CommandList } from './CommandList';
import {
  ACCESS_COLORS,
  ACCESS_NAMES,
  NetFile,
  NetrunData,
  NODE_ICONS,
  THEME,
} from './types';

export const NodePanel = () => {
  const { act, data } = useBackend<NetrunData>();
  const { selected, can_breach, breach, networks, selected_network } = data;
  if (!selected && selected_network) {
    const net = selected_network;
    return (
      <Section
        title={net.code}
        scrollable
        style={{ minHeight: '100%', overflowY: 'auto' }}
        buttons={<Icon name="network-wired" />}
      >
        <LabeledList>
          <LabeledList.Item label="Сеть">{net.name}</LabeledList.Item>
          <LabeledList.Item label="Защита">{net.security}</LabeledList.Item>
          <LabeledList.Item label="Доступ">
            <Box inline color={ACCESS_COLORS[net.access]} bold>
              {ACCESS_NAMES[net.access]}
            </Box>
            {net.has_key && <Icon name="key" ml={1} color={THEME.good} />}
          </LabeledList.Item>
        </LabeledList>
        {net.can_breach && (
          <Button
            mt={1}
            icon="key"
            color="caution"
            content="Подобрать доступ к сети"
            disabled={!!breach}
            onClick={() => act('breach', { kind: 'network', id: net.id })}
          />
        )}
        {net.can_breach && <AutoBreachButton kind="network" id={net.id} />}
        {net.access < 1 && !net.can_breach && (
          <Box mt={1} color={THEME.muted}>
            Нужен ключ сети или легальный доступ отдела.
          </Box>
        )}
        {net.log.length > 0 && (
          <Box
            mt={1}
            p={1}
            style={{
              background: THEME.bg,
              fontFamily: 'monospace',
              fontSize: '10px',
              color: THEME.muted,
            }}
          >
            {net.log.map((line, i) => (
              <Box key={i}>{line}</Box>
            ))}
          </Box>
        )}
      </Section>
    );
  }
  if (!selected) {
    return (
      <Section title="Сети" scrollable style={{ minHeight: '100%', overflowY: 'auto' }}>
        <Box color={THEME.muted} mb={1}>
          Выберите узел на карте или подберите доступ к сети.
        </Box>
        {networks
          .filter((net) => net.id !== 'web')
          .map((net) => (
            <Box
              key={net.id}
              p={1}
              mb={0.5}
              style={{
                background: THEME.bg,
                border: `1px solid ${net.reachable ? net.color : THEME.line}`,
                opacity: net.reachable ? 1 : 0.5,
              }}
            >
              <Box>
                <Box inline bold style={{ fontFamily: 'monospace', color: net.color }}>
                  {net.code}
                </Box>
                {net.has_key && <Icon name="key" ml={1} color={THEME.good} />}
                <Box inline ml={1} color={ACCESS_COLORS[net.access]}>
                  {ACCESS_NAMES[net.access]}
                </Box>
              </Box>
              <Box color={THEME.muted} fontSize="11px">
                {net.name} · защита {net.security} · узлов {net.nodes}
              </Box>
              <Box mt={0.5}>
                <Button
                  compact
                  icon="diagram-project"
                  content="Открыть"
                  disabled={!net.reachable}
                  onClick={() => act('select_network', { id: net.id })}
                />
                {net.can_breach && (
                  <Button
                    compact
                    icon="key"
                    color="caution"
                    content="Подобрать доступ"
                    disabled={!!breach}
                    onClick={() => act('breach', { kind: 'network', id: net.id })}
                  />
                )}
                {net.can_breach && <AutoBreachButton kind="network" id={net.id} disabled={!net.reachable} />}
              </Box>
            </Box>
          ))}
      </Section>
    );
  }
  return (
    <Section
      title={selected.name}
      scrollable
      style={{ minHeight: '100%', overflowY: 'auto' }}
      buttons={
        <Box inline>
          <Button
            icon="location-arrow"
            tooltip="Пеленг на узел — показать направление на карте"
            selected={data.waypoint?.address === selected.address}
            onClick={() => act('set_waypoint', { address: selected.address })}
          />
          <Button
            icon="window-maximize"
            content="Закрепить"
            tooltip="Открыть в закреплённых узлах"
            onClick={() => act('window_open', { address: selected.address })}
          />
          <Icon name={NODE_ICONS[selected.type] || 'circle'} ml={1} />
        </Box>
      }
    >
      <LabeledList>
        <LabeledList.Item label="Адрес">
          <Box inline style={{ fontFamily: 'monospace' }}>
            {selected.address}
          </Box>{' '}
          · {selected.network}
        </LabeledList.Item>
        <LabeledList.Item label="Состояние">
          <Box inline color={selected.online ? THEME.good : THEME.bad}>
            {selected.online ? 'в сети' : 'не отвечает'}
          </Box>
          {' · защита '}
          {selected.security}
        </LabeledList.Item>
        <LabeledList.Item label="Доступ">
          <Box inline color={ACCESS_COLORS[selected.access]} bold>
            {ACCESS_NAMES[selected.access]}
          </Box>
          {selected.legit < selected.access && (
            <Box inline color={THEME.warn} ml={1}>
              (без авторизации)
            </Box>
          )}
        </LabeledList.Item>
      </LabeledList>
      {selected.access < 1 && (
        <Box mt={1} color={THEME.warn}>
          Узел закрыт. Подберите доступ к узлу или его сети.
        </Box>
      )}
      {selected.lan && (
        <Box mt={1} p={1} style={{ background: THEME.bg, border: `1px solid ${selected.lan.color}` }}>
          <Box>
            <Icon name="network-wired" mr={1} color={selected.lan.color} />
            <Box inline bold style={{ fontFamily: 'monospace', color: selected.lan.color }}>
              {selected.lan.code}
            </Box>
            {selected.lan.has_key && <Icon name="key" ml={1} color={THEME.good} />}
            <Box inline ml={1} color={ACCESS_COLORS[selected.lan.access]}>
              {ACCESS_NAMES[selected.lan.access]}
            </Box>
          </Box>
          <Box color={THEME.muted} fontSize="11px">
            ЛВС: {selected.lan.name} · защита {selected.lan.security}
          </Box>
          <Box mt={0.5}>
            <Button
              compact
              icon="diagram-project"
              content="Открыть ЛВС"
              onClick={() => act('select_network', { id: selected.lan!.id })}
            />
            {selected.lan.can_breach && (
              <Button
                compact
                icon="key"
                color="caution"
                content="Подобрать доступ к ЛВС"
                disabled={!!breach}
                onClick={() => act('breach', { kind: 'network', id: selected.lan!.id })}
              />
            )}
            {selected.lan.can_breach && <AutoBreachButton kind="network" id={selected.lan.id} />}
          </Box>
        </Box>
      )}
      {selected.status.length > 0 && (
        <Box
          mt={1}
          p={1}
          style={{ background: THEME.bg, fontFamily: 'monospace', fontSize: '11px' }}
        >
          {selected.status.map((line, i) => (
            <Box key={i}>{line}</Box>
          ))}
        </Box>
      )}
      <Box mt={1}>
        <CommandList
          commands={selected.commands}
          onCommand={(id) => act('command', { id })}
        />
      </Box>
      {data.entity && data.entity.host !== selected.address && (
        <Button
          mt={1}
          icon="person-walking-arrow-right"
          color="good"
          content="Перейти в узел"
          disabled={!(selected.can_hop ?? (selected.access >= 2 && selected.online))}
          tooltip="Нужно разрешение на переход в соседний узел: доступ пользователя или ключ сети."
          onClick={() => act('hop', { address: selected.address })}
        />
      )}
      {data.entity && data.entity.host !== selected.address && (
        <Button
          mt={1}
          ml={1}
          icon="route"
          content="Пройти к узлу"
          tooltip="Автопроход шаг за шагом по уже открытым узлам (online и с доступом пользователя или ключом) до выбранного."
          onClick={() => act('travel', { address: selected.address })}
        />
      )}
      {can_breach && selected.access < 3 && (
        <Button
          mt={1}
          icon="key"
          color="caution"
          content="Подобрать доступ"
          disabled={!!breach || !selected.online}
          onClick={() => act('breach', { kind: 'node', id: selected.address })}
        />
      )}
      {can_breach && selected.access >= 1 && selected.access < 2 && <AutoBreachButton kind="node" id={selected.address} disabled={!selected.online} />}
      {selected.files && (
        <Box mt={2}>
          <Box color={THEME.muted} mb={0.5}>
            Хранилище узла: {selected.storage?.used}/{selected.storage?.capacity}
          </Box>
          {selected.files.length === 0 && <Box color={THEME.muted}>Пусто.</Box>}
          <div data-net-files="remote" style={{ maxHeight: '40vh', minHeight: 0, overflowY: 'auto', paddingRight: '4px' }}>
          {selected.files.map((file) => (
            <RemoteFile key={file.uid} file={file} root={selected.access >= 3} />
          ))}
          </div>
        </Box>
      )}
      {!!selected.logs?.length && (
        <Box mt={1} p={1} style={{ background: THEME.bg, whiteSpace: 'pre-wrap', fontFamily: 'monospace', maxHeight: '160px', overflowY: 'auto' }}>
          <Box color={THEME.muted} mb={0.5}>Журнал узла</Box>
          {selected.logs.map((line, index) => <div key={index}>{line}</div>)}
        </Box>
      )}
    </Section>
  );
};

const RemoteFile = (props: { file: NetFile; root: boolean }) => {
  const { act, data } = useBackend<NetrunData>();
  const { file, root } = props;
  return (
    <Box mb={0.5} p={0.5} data-net-file-row="remote" style={{ fontFamily: 'monospace', borderBottom: `1px solid ${THEME.line}` }}>
      <Box style={{ minWidth: 0, overflowWrap: 'anywhere' }}>
        <Icon name={fileIcon(file.kind)} mr={1} />
        {file.name}
        <Box inline ml={1} color={THEME.muted}>[{file.size}]</Box>
      </Box>
      <Box data-net-file-actions="remote" mt={0.5} style={{ display: 'flex', flexWrap: 'wrap', gap: '3px' }}>
        {file.kind === 'text' && (
          <Button compact icon="eye" tooltip="Прочитать" onClick={() => act('read', { uid: file.uid })} />
        )}
        <Button compact icon="download" tooltip="Скачать" onClick={() => act('download', { uid: file.uid })} />
        {data.shard && (
          <Button
            compact
            icon="sd-card"
            tooltip="Скачать на шард"
            onClick={() => act('download', { uid: file.uid, to_shard: true })}
          />
        )}
        {root && (
          <Button compact icon="trash" color="bad" tooltip="Удалить" onClick={() => act('delete_remote', { uid: file.uid })} />
        )}
      </Box>
    </Box>
  );
};

export const fileIcon = (kind: string) => {
  switch (kind) {
    case 'key':
      return 'key';
    case 'daemon':
      return 'gear';
    case 'seed':
      return 'seedling';
    case 'photo':
      return 'image';
    case 'techweb_link':
      return 'link';
    case 'techweb':
      return 'flask';
    default:
      return 'file-lines';
  }
};

/** Формат файла: расширение из имени, иначе метка по типу. */
export const fileFormat = (name: string, kind: string) => {
  const dot = name.lastIndexOf('.');
  if (dot > 0 && dot < name.length - 1) {
    return name.slice(dot + 1).toUpperCase();
  }
  const labels: Record<string, string> = {
    key: 'KEY',
    daemon: 'EXE',
    seed: 'SEED',
    photo: 'IMG',
    techweb: 'WEB',
    techweb_link: 'LINK',
    text: 'TXT',
  };
  return labels[kind] || 'DAT';
};
