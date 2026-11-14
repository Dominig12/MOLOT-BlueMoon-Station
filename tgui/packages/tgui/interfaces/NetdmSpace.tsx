import { BooleanLike } from 'common/react';
import { useMemo, useState } from 'react';

import { useBackend } from '../backend';
import { Box, Button, Dropdown, Input, LabeledList, NoticeBox, Section, Stack, Table } from '../components';
import { Window } from '../layouts';
import { TopologyCanvas } from './NetdmTopology';
import { FLAG_APC, FLAG_UNPOWERED, parseView, View } from './NetdmTopology/model';
import { SceneFilters } from './NetdmTopology/scene';

type Service = { instance: string; type: string; node: string; stale: BooleanLike };

type Presence = {
  status: string;
  presence?: number;
  host?: string;
  generation?: number;
  state?: string;
  reason?: string;
  to?: string;
  arriveIn?: number;
};

/** DM sends its booleans as 0/1: render them only through `!!`. */
type Data = {
  title: string;
  z: number;
  levels: number[];
  nodes: unknown[];
  edges: unknown[];
  down: unknown[];
  services: Service[];
  presence: Presence | null;
  hostNode: string | null;
  log: string[];
  revision: number;
};

const FILTERS: SceneFilters = { radio: true, devices: true };
const FALLBACK_ROWS = 200;

const STATE_TEXT: Record<string, string> = {
  active: 'в сети',
  suspended: 'приостановлено',
  moving: 'в пути',
  ended: 'завершено',
};

const REASON_TEXT: Record<string, string> = {
  operator_away: 'окно закрыто',
  host_unpowered: 'у хоста нет питания',
  host_unreachable: 'хост не отвечает',
  host_lost: 'хост потерян',
  entry_lost: 'потеряна точка входа',
  operator_gone: 'оператор долго отсутствовал',
  left: 'оператор вышел',
  lost_in_transit: 'потеряно в пути',
  'returned: route_lost': 'вернулось: маршрут оборвался',
};

/** What the operator knows of one node: its kind, freshness and the services seen there. */
const NodePanel = (props: { view: View; id: string | null; services: Service[]; presenceHost: string | null;
  onMove: (instance: string) => void }) => {
  const { id, view, services, presenceHost, onMove } = props;
  const node = id ? view.nodes.get(id) : undefined;
  if (!id || !node) {
    return <Section title="Узел">Выберите узел на карте.</Section>;
  }
  const here = services.filter(service => service.node === id);
  return (
    <Section title={`Узел ${id}`}>
      <LabeledList>
        <LabeledList.Item label="Тип">{node.flags & FLAG_APC ? 'ретранслятор (АПЦ)' : 'устройство'}</LabeledList.Item>
        <LabeledList.Item label="Сведения">{node.flags & FLAG_UNPOWERED ? 'устарели' : 'свежие'}</LabeledList.Item>
        <LabeledList.Item label="Клетка">{node.x}, {node.y}</LabeledList.Item>
      </LabeledList>
      {here.length === 0 && <Box color="label" mt={0.5}>Известных сервисов нет.</Box>}
      {here.map(service => (
        <Stack key={service.instance} mt={0.5} align="center">
          <Stack.Item grow color={service.stale ? 'label' : undefined}>
            {service.instance} · {service.type}
          </Stack.Item>
          {service.type === 'network.shell' && service.instance !== presenceHost && (
            <Stack.Item>
              <Button icon="route" onClick={() => onMove(service.instance)}>Перейти</Button>
            </Stack.Item>
          )}
        </Stack>
      ))}
    </Section>
  );
};

/** A shell line the presence runs where it stands. */
const ActionBox = (props: { line: string; enabled: boolean; onLine: (value: string) => void; onSend: () => void }) => (
  <Section title="Действие присутствия">
    <Stack>
      <Stack.Item grow>
        <Input
          fluid
          maxLength={1024}
          placeholder="links | where state -ne up"
          value={props.line}
          onInput={(_event: unknown, value: string) => props.onLine(value)}
          onEnter={() => props.onSend()} />
      </Stack.Item>
      <Stack.Item>
        <Button icon="play" disabled={!props.enabled} onClick={() => props.onSend()} />
      </Stack.Item>
    </Stack>
  </Section>
);

const FallbackList = (props: { view: View; reason: string; onSelect: (id: string) => void; onRetry: () => void }) => {
  const rows = [...props.view.nodes.values()].slice(0, FALLBACK_ROWS);
  return (
    <Section fill scrollable title="Известные узлы" buttons={<Button icon="redo" onClick={props.onRetry}>Повторить</Button>}>
      <NoticeBox>Графический режим недоступен ({props.reason}). Знание показано списком.</NoticeBox>
      <Table>
        {rows.map(node => (
          <Table.Row key={node.id}>
            <Table.Cell>
              <Button onClick={() => props.onSelect(node.id)}>{node.id}</Button>
            </Table.Cell>
            <Table.Cell>{node.x}, {node.y}</Table.Cell>
            <Table.Cell>{node.flags & FLAG_UNPOWERED ? 'устарело' : 'свежее'}</Table.Cell>
          </Table.Row>
        ))}
      </Table>
    </Section>
  );
};

/**
 * P12.4 · the player's network window: what the operator knows (stale items drawn muted), its presence,
 * and the presence commands. Every button is a network command; the window draws what came back.
 */
export const NetdmSpace = () => {
  const { act, data } = useBackend<Data>();
  const view = useMemo(
    () => parseView({ nodes: data.nodes, edges: data.edges, down: data.down }),
    [data.nodes, data.edges, data.down],
  );
  const [selected, setSelected] = useState<string | null>(null);
  const [failure, setFailure] = useState<string | null>(null);
  const [radius, setRadius] = useState(3);
  const [line, setLine] = useState('');
  const presence = data.presence;
  const inside = !!presence?.presence && presence.state !== 'ended' && presence.status !== 'none';
  const shown = selected ?? data.hostNode ?? null;
  const reason = presence?.reason ? REASON_TEXT[presence.reason] ?? presence.reason : null;
  const send = () => {
    const trimmed = line.trim();
    if (trimmed.length > 0 && trimmed.length <= 1024) {
      act('act', { line: trimmed });
      setLine('');
    }
  };

  return (
    <Window width={860} height={600} title={`Сеть: ${data.title}`}>
      <Window.Content>
        <Stack fill vertical>
          <Stack.Item>
            <Section>
              <Stack align="center" wrap>
                <Stack.Item grow>
                  {inside ? (
                    <Box>
                      Присутствие №{presence!.presence}: {STATE_TEXT[presence!.state ?? ''] ?? presence!.state}
                      {presence!.state === 'moving'
                        ? ` → ${presence!.to}, ещё ${presence!.arriveIn ?? 0} с`
                        : ` на ${presence!.host}`}
                      {` · поколение ${presence!.generation ?? 1}`}
                      {reason && ` · ${reason}`}
                    </Box>
                  ) : (
                    <Box color="label">
                      Вы не в сети.{reason && ` Последнее присутствие: ${reason}.`}
                    </Box>
                  )}
                </Stack.Item>
                <Stack.Item>
                  {inside ? (
                    <Button.Confirm icon="sign-out-alt" content="Выйти" confirmContent="Завершить присутствие?" onClick={() => act('leave')} />
                  ) : (
                    <Button icon="sign-in-alt" onClick={() => act('enter')}>Войти</Button>
                  )}
                </Stack.Item>
                <Stack.Item>
                  <Dropdown
                    width="90px"
                    selected={radius}
                    options={[1, 2, 3, 4, 5, 6, 7, 8].map(value => ({ value, displayText: `${value} хоп.` }))}
                    onSelected={(value: number) => setRadius(value)} />
                </Stack.Item>
                <Stack.Item>
                  <Button icon="satellite-dish" onClick={() => act('scan', { radius })}>Сканировать</Button>
                </Stack.Item>
                {data.levels.length > 1 && (
                  <Stack.Item>
                    <Dropdown
                      width="90px"
                      selected={data.z}
                      options={data.levels.map(level => ({ value: level, displayText: `Z${level}` }))}
                      onSelected={(value: number) => {
                        setSelected(null);
                        act('level', { z: value });
                      }} />
                  </Stack.Item>
                )}
              </Stack>
            </Section>
          </Stack.Item>
          <Stack.Item grow>
            <Stack fill>
              <Stack.Item grow>
                {view.nodes.size === 0 ? (
                  <Section fill>
                    <Box color="label">Вы пока ничего не знаете о сети. Сканируйте, чтобы увидеть окрестность.</Box>
                  </Section>
                ) : failure ? (
                  <FallbackList view={view} reason={failure} onSelect={setSelected} onRetry={() => setFailure(null)} />
                ) : (
                  <TopologyCanvas
                    view={view}
                    levelKey={String(data.z)}
                    selected={shown}
                    filters={FILTERS}
                    fitRequest={0}
                    onSelect={setSelected}
                    onFailure={setFailure}
                    onReport={() => undefined} />
                )}
              </Stack.Item>
              <Stack.Item basis="300px">
                <Stack fill vertical>
                  <Stack.Item>
                    <NodePanel
                      view={view}
                      id={shown}
                      services={data.services}
                      presenceHost={inside ? presence!.host ?? null : null}
                      onMove={instance => act('move', { to: instance })} />
                  </Stack.Item>
                  <Stack.Item>
                    <ActionBox line={line} enabled={inside} onLine={setLine} onSend={send} />
                  </Stack.Item>
                  <Stack.Item grow>
                    <Section fill scrollable title="Журнал">
                      {data.log.length === 0 && <Box color="label">Пусто.</Box>}
                      {[...data.log].reverse().map((entry, index) => (
                        <Box key={index}>{entry}</Box>
                      ))}
                    </Section>
                  </Stack.Item>
                </Stack>
              </Stack.Item>
            </Stack>
          </Stack.Item>
        </Stack>
      </Window.Content>
    </Window>
  );
};
