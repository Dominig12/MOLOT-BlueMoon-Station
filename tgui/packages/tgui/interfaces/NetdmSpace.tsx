import { BooleanLike } from 'common/react';
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';

import { useBackend } from '../backend';
import { Box, Button, Dropdown, Input, LabeledList, NoticeBox, ProgressBar, Section, Stack, Table } from '../components';
import { Window } from '../layouts';
import { isSelectedPreview, nodeTravelChoice, NodeTravelChoice } from './netdmNodeTravel';
import { NearbyDestination, nearbyDestinations } from './netdmPresenceNavigation';
import { SHELL_COMMANDS, ShellDynamicPool, tabComplete } from './netdmShell';
import { TopologyCanvas } from './NetdmTopology';
import { MapChrome } from './NetdmTopology/MapChrome';
import { countActivityNodes, FLAG_APC, FLAG_UNPOWERED, isOffline, parseView, View } from './NetdmTopology/model';
import { NodePresenceCounts, SceneFilters, SceneOperator, SceneRoute } from './NetdmTopology/scene';

// PixiJS resizes its canvas from a ResizeObserver; when the browser coalesces a layout pass it reports
// "ResizeObserver loop completed with undelivered notifications" as a window error, and TGUI turns any
// window error into the crash screen. The warning is benign for this interface, so keep it from reaching
// that handler. Real errors are untouched.
if (typeof window !== 'undefined') {
  window.addEventListener('error', event => {
    if (String(event.message || '').includes('ResizeObserver loop')) {
      event.stopImmediatePropagation();
      event.preventDefault();
    }
  }, true);
}

type Service = { instance: string; type: string; node: string; stale: BooleanLike; canControlAlarm?: BooleanLike };

type Presence = {
  status: string;
  presence?: number;
  host?: string;
  generation?: number;
  state?: string;
  reason?: string;
  to?: string;
  arriveIn?: number;
  travelSeconds?: number;
  route?: (string | null)[];
  radioLegs?: number[];
  limited?: BooleanLike;
  breakFrom?: string;
  breakTo?: string;
  breakKind?: 'cable' | 'radio' | 'endpoint';
  persona?: Persona | null;
  threat?: string;
};

type Persona = { name: string; signature: string; status?: string; role?: string; colour: number; revision?: number };

type LifeBot = {
  bot: number;
  name: string;
  signature: string;
  colour: number;
  goal: string;
  node: string;
  state: string;
  moves: number;
};

type LifeOperator = {
  node: string;
  status: string;
  role: string;
  name: string;
  signature: string;
  colour: number;
  state: string;
  threat: string;
};

type HackKey = {
  node: string;
  label: string;
  ttl: number;
};

type HackState = {
  status?: string | null;
  code?: string | null;
  target?: string | null;
  keys?: HackKey[] | null;
  masked?: BooleanLike;
};

type LifeIncident = {
  at: number;
  kind: string;
  node: string;
  text: string;
};

type LifeEvent = { seq: number; kind: string; node: string; name: string; text: string };

type RoutePreview = {
  target: string;
  status: string;
  nodes?: (string | null)[];
  seconds?: number;
  hops?: number;
  radioHops?: number;
  radioLegs?: number[];
  limited?: BooleanLike;
};

type AlarmWatch = {
  instance: string;
  node: string;
  z: number | null;
  state: 'waiting' | 'clear' | 'warning' | 'danger' | 'alarm' | 'offline' | 'paused';
  sample: { pressureKPa: number; temperatureK: number } | null;
  age: number | null;
};

type MachineCommand = {
  instance: string;
  enabled: BooleanLike;
  status: 'sending' | 'sent' | 'applied' | 'rejected' | 'not_delivered' | 'no_receipt' | 'unknown';
  operation?: string;
  reason?: string;
  source?: string;
  zoneAlarm?: BooleanLike;
  sourceActive?: BooleanLike;
};

type NodeChat = {
  channel?: BooleanLike;
  node: string;
  visit: string;
  received: number;
  messages: { id: string; text: string; sender: string; own: BooleanLike }[];
  status?: string | null;
};

type ChatProgress = Pick<NodeChat, 'visit' | 'received'>;
type ChatOpening = { previousRead: ChatProgress | null; snapshot: ChatProgress | null };

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
  otherPresences?: NodePresenceCounts;
  chat?: NodeChat | null;
  incidents?: LifeIncident[] | null;
  hack?: HackState | null;
  log: string[];
  revision: number;
  alarmPending: BooleanLike;
  alarmWatch: AlarmWatch | null;
  machineCommand: MachineCommand | null;
  routePreview: RoutePreview | null;
  immersed: BooleanLike;
  immersionEnabled: BooleanLike;
  immersionReason: string;
  immersedSeconds?: number;
  persona: Persona | null;
  life?: { bots: LifeBot[]; activity: LifeEvent[]; operators?: LifeOperator[] } | null;
};

const FILTERS: SceneFilters = { radio: true, devices: true };
const FALLBACK_ROWS = 200;
const OTHER_PRESENCE_COLOR = '#d19aff';
const CHAT_LIMIT = 160;

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
  'returned: cancelled': 'вернулось на исходный узел',
};

const ROUTE_STATUS: Record<string, string> = {
  pending: 'Запрашиваем маршрут…',
  invalid_argument: 'Выберите другой узел для перехода.',
  unreachable: 'Цель сейчас недостижима.',
  out_of_reach: 'Терминал потерял связь с присутствием.',
  suspended: 'Сначала возобновите присутствие.',
  moving: 'Дождитесь завершения перехода.',
  forbidden: 'Вход на этот узел недоступен.',
  limit_exceeded: 'На целевом узле нет места для присутствия.',
  no_presence: 'Войдите в сеть для перехода.',
  busy: 'Модуль занят. Запросите маршрут ещё раз.',
};

const BREAK_TEXT: Record<NonNullable<Presence['breakKind']>, string> = {
  cable: 'Оборвалось проводное соединение',
  radio: 'Пропала радиосвязь',
  endpoint: 'Узел перестал отвечать',
};

const WATCH_STATUS = {
  waiting: { text: 'Ожидание замера', color: 'label' },
  clear: { text: 'В норме', color: 'good' },
  warning: { text: 'Отклонение', color: 'average' },
  danger: { text: 'Опасная атмосфера', color: 'bad' },
  alarm: { text: 'Тревога в зоне', color: 'bad' },
  offline: { text: 'Нет связи', color: 'bad' },
  paused: { text: 'Наблюдение приостановлено', color: 'label' },
};

const MACHINE_STATUS = {
  sending: { text: 'Передаём команду…', color: 'label' },
  sent: { text: 'Ожидаем ответа от панели…', color: 'label' },
  applied: { text: 'Панель подтвердила выполнение', color: 'good' },
  rejected: { text: 'Команда отклонена', color: 'bad' },
  not_delivered: { text: 'Команда не дошла до панели', color: 'bad' },
  no_receipt: { text: 'Host зафиксировал выполнение. Квитанция не пришла.', color: 'average' },
  unknown: { text: 'Нет данных об исходе команды', color: 'average' },
};

const MACHINE_REASON: Record<string, string> = {
  access_denied: 'У оператора нет доступа к этой панели.',
  access_revoked: 'Доступ к сервису отозван.',
  alarm_offline: 'Атмосферная панель отключена.',
  alarm_outside_station: 'Панель недоступна из сети станции.',
  alarms_disabled: 'Тревоги в этой зоне отключены.',
  denied: 'Требуется доступ к атмосферной панели.',
  forbidden: 'Требуется доступ к атмосферной панели.',
  busy: 'Сетевой модуль занят.',
  unreachable: 'Маршрут до панели недоступен.',
  out_of_reach: 'Терминал потерял связь с присутствием.',
  origin_unavailable: 'Узел отправки потерял связь или сменил оболочку.',
  invalid_route: 'Маршрут до панели недоступен.',
  no_answer: 'Время ожидания ответа истекло.',
  offline: 'Атмосферная панель отключена.',
  suspended: 'Присутствие приостановлено.',
  moving: 'Присутствие в пути.',
  no_presence: 'Войдите в сеть.',
};

const CHAT_STATUS: Record<string, string> = {
  sending: 'Отправляем…',
  sent: 'Сообщение отправлено.',
  rate_limited: 'Подождите перед следующим сообщением.',
  busy: 'Чат занят. Попробуйте ещё раз.',
  invalid_argument: 'Сообщение не принято.',
  invalid_text: 'Сообщение не принято.',
  no_answer: 'Нет подтверждения отправки.',
  refused: 'Не удалось отправить сообщение.',
  no_presence: 'Войдите в сеть, чтобы написать.',
  suspended: 'Возобновите присутствие, чтобы написать.',
  moving: 'Дождитесь завершения перехода.',
  out_of_reach: 'Терминал потерял связь с присутствием.',
  stale_chat: 'Подключение к чату изменилось. Попробуйте ещё раз.',
};

/** What the operator knows of one node: its kind, freshness and the services seen there. */
const NodePanel = (props: { view: View; id: string | null; services: Service[];
  otherPresences: number; travel: NodeTravelChoice;
  active: boolean; alarmPending: boolean; machinePending: boolean; routePending: boolean; watchedAlarm: string | null;
  onPreview: (instance: string) => void; onTrace: (id: string) => void; onWatchAlarm: (instance: string) => void;
  onReadAlarm: (instance: string) => void; onSetAlarm: (instance: string, enabled: boolean) => void }) => {
  const { id, view, services, otherPresences, travel, active, alarmPending, machinePending, routePending, watchedAlarm,
    onPreview, onTrace, onReadAlarm, onWatchAlarm, onSetAlarm } = props;
  const node = id ? view.nodes.get(id) : undefined;
  if (!id || !node) {
    return <Section title="Узел">Выберите узел на карте.</Section>;
  }
  const here = services.filter(service => service.node === id);
  const stale = isOffline(node.flags);
  const travelHint = {
    here: 'Вы на этом узле.',
    unknown: 'Этот узел ещё не обнаружен.',
    offline: 'Узел не работает — переход пока невозможен.',
    no_shell: 'Точка входа на этом узле пока не обнаружена.',
    stale: 'Сведения о точке входа устарели. Обновите карту.',
    ready: 'Точка входа известна. Маршрут нужно проверить.',
  }[travel.state];
  return (
    <Section
      title={`Узел ${id}`}
      buttons={(
        <>
          {travel.state === 'ready' && (
            <Button icon="route" color="good"
              disabled={!active || routePending}
              tooltip="Запросить у Host маршрут. Для подтверждения перехода нажмите Enter после ответа."
              onClick={() => travel.instance && onPreview(travel.instance)}>
              Проверить переход · G
            </Button>
          )}
          <Button icon="signal" disabled={!active} onClick={() => onTrace(id)}>
            Проверить связь
          </Button>
        </>
      )}>
      <LabeledList>
        <LabeledList.Item label="Тип">{node.flags & FLAG_APC ? 'ретранслятор (АПЦ)' : 'устройство'}</LabeledList.Item>
        <LabeledList.Item label="Сведения">{stale ? 'устарели' : 'свежие'}</LabeledList.Item>
        <LabeledList.Item label="Клетка">{node.x}, {node.y}</LabeledList.Item>
        {otherPresences > 0 && (
          <LabeledList.Item label="Чужие присутствия">
            <Box color={OTHER_PRESENCE_COLOR}>◆ {otherPresences}</Box>
          </LabeledList.Item>
        )}
      </LabeledList>
      <Box color={travel.state === 'here' ? 'good' : 'label'} mt={0.5}>{travelHint}</Box>
      {here.length === 0 && <Box color="label" mt={0.5}>Известных сервисов нет.</Box>}
      {here.map(service => (
        <Box key={service.instance} mt={0.5}>
          <Stack align="center" wrap>
            <Stack.Item grow color={service.stale ? 'label' : undefined}>
              <Box title={service.instance}>
                {service.type === 'atmos.alarm' ? 'Датчик атмосферы' : service.type === 'network.shell' ? 'Оболочка узла' : `${service.instance} · ${service.type}`}
              </Box>
            </Stack.Item>
            {service.type === 'atmos.alarm' && (
              <Stack.Item>
                <Button
                  icon="tachometer-alt"
                  disabled={!active || stale || !!service.stale || alarmPending}
                  onClick={() => onReadAlarm(service.instance)}>
                  Замер
                </Button>
                <Button
                  icon="bell"
                  selected={watchedAlarm === service.instance}
                  disabled={!active || stale || !!service.stale || watchedAlarm === service.instance}
                  onClick={() => onWatchAlarm(service.instance)}>
                  {watchedAlarm === service.instance ? 'Под наблюдением' : 'Следить'}
                </Button>
              </Stack.Item>
            )}
          </Stack>
          {service.type === 'atmos.alarm' && !!service.canControlAlarm && (
            <Box mt={0.5}>
              <Button.Confirm
                icon="exclamation-circle"
                content="Поднять тревогу"
                confirmContent="Поднять тревогу панели?"
                disabled={!active || stale || !!service.stale || machinePending}
                onClick={() => onSetAlarm(service.instance, true)} />
              <Button.Confirm
                icon="bell-slash"
                content="Снять тревогу панели"
                confirmContent="Снять тревогу панели?"
                disabled={!active || stale || !!service.stale || machinePending}
                onClick={() => onSetAlarm(service.instance, false)} />
            </Box>
          )}
          {service.type === 'atmos.alarm' && active && !stale && !service.stale && !service.canControlAlarm && (
            <Box color="label">Для управления нужны доступ и разблокированная панель.</Box>
          )}
        </Box>
      ))}
    </Section>
  );
};

const RouteNodes = (props: { nodes: readonly (string | null)[]; radioLegs: readonly number[] }) => (
  <Box mt={0.5} style={{ overflowWrap: 'anywhere' }}>
    {props.nodes.map((id, index) => `${index === 0 ? '' : props.radioLegs.includes(index) ? ' ⇢ ' : ' → '}${id || '?'}`).join('')}
  </Box>
);

const RoutePanel = (props: { preview: RoutePreview | null; presence: Presence | null; canMove: boolean;
  onMove: (target: string) => void; onRetry: (target: string) => void; onClear: () => void; onAbort: () => void }) => {
  const { preview, presence, canMove, onMove, onRetry, onAbort, onClear } = props;
  const close = <Button icon="times" tooltip="Закрыть маршрут" onClick={onClear} />;
  if (presence?.state === 'moving') {
    const remaining = presence.arriveIn ?? 0;
    const elapsed = presence.travelSeconds ? 1 - remaining / presence.travelSeconds : 0;
    return (
      <Section
        title="Переход"
        buttons={<Button icon="undo" tooltip="Вернуться на исходный узел" onClick={onAbort}>Прервать</Button>}>
        <ProgressBar color="teal" value={Math.max(0, Math.min(elapsed, 1))}>До прибытия {remaining} с</ProgressBar>
        {!!presence.route?.length && <RouteNodes nodes={presence.route} radioLegs={presence.radioLegs ?? []} />}
        {!!presence.limited && <Box color="label">Часть пути неизвестна.</Box>}
      </Section>
    );
  }
  if (preview?.status === 'ready') {
    return (
      <Section
        title="Предпросмотр маршрута"
        buttons={(
          <>
            <Button icon="sign-in-alt" disabled={!canMove} onClick={() => onMove(preview.target)}>
              Перейти
            </Button>
            {close}
          </>
        )}>
        <Box color="#ffc36a">{preview.seconds} с · переходов {preview.hops ?? 0} · по радио {preview.radioHops ?? 0}</Box>
        {!!preview.nodes?.length && <RouteNodes nodes={preview.nodes} radioLegs={preview.radioLegs ?? []} />}
        {!!preview.limited && <Box color="label">Часть пути неизвестна.</Box>}
      </Section>
    );
  }
  if (preview) {
    return (
      <Section
        title="Предпросмотр маршрута"
        buttons={(
          <>
            {preview.status !== 'pending' && (
              <Button disabled={!canMove} icon="redo" onClick={() => onRetry(preview.target)}>Повторить</Button>
            )}
            {close}
          </>
        )}>
        <Box color={preview.status === 'pending' ? 'label' : 'average'}>
          {ROUTE_STATUS[preview.status] ?? 'Модуль не вернул маршрут.'}
        </Box>
      </Section>
    );
  }
  if (presence?.breakKind) {
    return (
      <Section title="Переход прерван">
        <Box color="bad">
          {BREAK_TEXT[presence.breakKind]}
          {presence.breakFrom && ` · ${presence.breakFrom}`}
          {presence.breakTo && `${presence.breakFrom ? ' → ' : ' · '}${presence.breakTo}`}
        </Box>
      </Section>
    );
  }
  return null;
};

/** A fast hop selector for players who live inside the network.
 * These are known links only: the server must still approve preview_move and move.
 */
const NearbyMovementPanel = (props: {
  destinations: NearbyDestination[];
  active: boolean;
  moving: boolean;
  pending: boolean;
  onPreview: (destination: NearbyDestination) => void;
}) => (
  <Section title="Известные переходы рядом">
    {props.destinations.length === 0 ? (
      <Box color="label">
        Рядом не обнаружены точки перехода. Просканируйте сеть или выберите узел на карте.
      </Box>
    ) : (
      <>
        <Box color="label" mb={0.5}>
          Выберите точку, чтобы проверить маршрут. Переход не начинается автоматически.
        </Box>
        <Stack wrap>
          {props.destinations.map(destination => (
            <Stack.Item key={destination.node}>
              <Button
                icon={destination.radio ? 'wifi' : 'network-wired'}
                disabled={!props.active || props.moving || props.pending || destination.unavailable}
                tooltip={destination.unavailable
                  ? 'Известная связь или точка перехода сейчас недоступна'
                  : 'Запросить маршрут к этому узлу'}
                onClick={() => props.onPreview(destination)}>
                Узел {destination.node}{destination.radio ? ' · радио' : ''}
              </Button>
            </Stack.Item>
          ))}
        </Stack>
        {props.destinations.some(destination => destination.unavailable) && (
          <Box color="label" mt={0.5}>Недоступные точки показаны, но переход к ним заблокирован.</Box>
        )}
      </>
    )}
  </Section>
);

const AlarmWatchPanel = (props: { watch: AlarmWatch; onSelect: () => void; onStop: () => void }) => {
  const { watch, onSelect, onStop } = props;
  const { text, color } = WATCH_STATUS[watch.state];
  return (
    <Section
      title="Наблюдение за атмосферой"
      buttons={<Button icon="times" tooltip="Остановить наблюдение" onClick={onStop} />}>
      <Stack align="center">
        <Stack.Item grow><Box bold color={color}>{text}</Box></Stack.Item>
        <Stack.Item><Button icon="crosshairs" onClick={onSelect}>Узел {watch.node}</Button></Stack.Item>
      </Stack>
      {watch.sample && (
        <Box mt={0.5}>
          {`${watch.sample.pressureKPa} кПа · ${watch.sample.temperatureK} K`}
          {watch.age !== null && <Box inline ml={0.5} color="label">{watch.age} с назад</Box>}
        </Box>
      )}
    </Section>
  );
};

const MachineCommandPanel = (props: { command: MachineCommand }) => {
  const { instance, enabled, status, operation, reason, source, zoneAlarm, sourceActive } = props.command;
  const { text, color } = MACHINE_STATUS[status] ?? MACHINE_STATUS.unknown;
  return (
    <Section title="Команда атмосферной панели">
      <Box title={instance}>{enabled ? 'Поднять тревогу' : 'Снять тревогу панели'}</Box>
      <Box aria-live="polite" bold color={color}>{text}</Box>
      {status === 'applied' && zoneAlarm !== null && sourceActive !== null && (
        <Box color={zoneAlarm ? 'average' : 'label'}>
          {sourceActive ? 'Тревога панели активна' : 'Тревога панели снята'}
          {zoneAlarm && !sourceActive ? ' · в зоне остались другие тревоги' : ''}
        </Box>
      )}
      {reason && <Box color="label">{MACHINE_REASON[reason] ?? reason}</Box>}
      {(source || operation) && (
        <Box color="label">
          {source && `Узел отправки ${source}`}
          {source && operation && ' · '}
          {operation && `Операция №${operation}`}
        </Box>
      )}
    </Section>
  );
};

/** A shell line the presence runs where it stands: Tab completion, history and a usage hint. */
const ActionBox = (props: {
  line: string;
  enabled: boolean;
  dynamic: ShellDynamicPool;
  onLine: (value: string) => void;
  onSend: () => void;
}) => {
  const [history, setHistory] = useState<string[]>([]);
  const [historyIndex, setHistoryIndex] = useState(0);
  const [draft, setDraft] = useState('');
  const recall = (next: number) => {
    if (next < 0 || next > history.length || next === historyIndex) {
      return;
    }
    if (historyIndex === history.length) {
      setDraft(props.line);
    }
    setHistoryIndex(next);
    props.onLine(history[next] ?? draft);
  };
  const submit = () => {
    const text = props.line.trim();
    if (text.length === 0) {
      return;
    }
    const next = [...history.filter(entry => entry !== text), text].slice(-32);
    setHistory(next);
    setHistoryIndex(next.length);
    setDraft('');
    props.onSend();
  };
  const first = props.line.trim().split(/\s+/)[0];
  const hint = SHELL_COMMANDS.find(command => command.name === first)?.usage
    ?? 'Tab — автодополнение · ↑↓ — история · help — справка';
  return (
    <Section
      title="Командная строка"
      buttons={(
        <>
          <Button icon="plug" onClick={() => props.onLine('api')}>API</Button>
          <Button icon="question-circle" onClick={() => props.onLine('help')}>Справка</Button>
        </>
      )}>
      <Stack align="center">
        <Stack.Item grow>
          <div className="Input Input--fluid Input--monospace">
            <div className="Input__baseline" aria-hidden="true">.</div>
            <input
              className="Input__input"
              aria-label="Командная строка сети"
              autoComplete="off"
              spellCheck={false}
              maxLength={1024}
              placeholder="links | where state -ne up"
              value={props.line}
              onChange={event => props.onLine(event.currentTarget.value)}
              onKeyDown={event => {
                if (event.nativeEvent.isComposing) {
                  return;
                }
                if (event.key === 'Tab') {
                  event.preventDefault();
                  props.onLine(tabComplete(props.line, props.dynamic));
                  return;
                }
                if (event.key === 'Enter') {
                  event.preventDefault();
                  submit();
                  return;
                }
                if (event.key === 'ArrowUp' || event.key === 'ArrowDown') {
                  event.preventDefault();
                  recall(historyIndex + (event.key === 'ArrowUp' ? -1 : 1));
                }
              }} />
          </div>
          <Box mt={0.5} color="label" fontSize="0.9em">{hint}</Box>
        </Stack.Item>
        <Stack.Item>
          <Button icon="play" disabled={!props.enabled || !props.line.trim()} onClick={submit}>
            Выполнить
          </Button>
        </Stack.Item>
      </Stack>
    </Section>
  );
};

const FallbackList = (props: { view: View; reason: string; otherPresences?: NodePresenceCounts; activity?: Readonly<Record<string, number>>;
  agents?: readonly { node: string; goal: string; label: string }[];
  operators?: readonly SceneOperator[];
  onSelect: (id: string) => void; onRetry: () => void }) => {
  const rows = [...props.view.nodes.values()].slice(0, FALLBACK_ROWS);
  const otherPresences: NodePresenceCounts = props.otherPresences ?? {};
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
            <Table.Cell>
            <Table.Cell>
              {props.activity?.[node.id] ? `Активность: ${props.activity[node.id]}` : null}
              {props.agents?.some(agent => agent.node === node.id) ? " ◆ агент" : null}
              {props.operators?.some(operator => operator.node === node.id) ? " ◉ оператор" : null}
            </Table.Cell>
              {otherPresences[node.id] > 0 && (
                <Box color={OTHER_PRESENCE_COLOR}>Чужие присутствия: {otherPresences[node.id]}</Box>
              )}
            </Table.Cell>
          </Table.Row>
        ))}
      </Table>
    </Section>
  );
};

const firstUnreadMessage = (chat: NodeChat, readThrough: number, openedThrough: number) => {
  // The snapshot is a suffix of the inbox. Only incoming rows advance received.
  let received = chat.received;
  let first: string | null = null;
  for (let index = chat.messages.length - 1; index >= 0 && received > readThrough; index--) {
    const message = chat.messages[index];
    if (message.own) {
      continue;
    }
    if (received <= openedThrough) {
      first = message.id;
    }
    received--;
  }
  return first;
};

const isAtChatEnd = (list: HTMLDivElement) => list.scrollHeight - list.scrollTop - list.clientHeight <= 2;

const NodeChatPanel = (props: { chat: NodeChat | null; state?: string; firstUnread: string | null;
  onJournal: () => void; onRead: (visit: string, received: number) => void; onSend: (node: string, text: string) => void;
  onChannel: () => void }) => {
  const { chat, state, firstUnread, onJournal, onRead, onSend, onChannel } = props;
  const [draft, setDraft] = useState('');
  const [heldHistory, setHeldHistory] = useState<{ chat: NodeChat; firstUnread: string | null } | null>(null);
  const submitted = useRef<string | null>(null);
  const scrollable = useRef<HTMLDivElement>(null);
  const unreadDivider = useRef<HTMLDivElement>(null);
  const opened = useRef(false);
  const jumpToMessage = useRef<string | null>(null);
  const pending = chat?.status === 'sending';
  const text = draft.trim();
  // Keep the displayed rows intact while reading, even as the Host evicts old messages.
  const history = chat && heldHistory?.chat.visit === chat.visit ? heldHistory : null;
  const messages = (history?.chat ?? chat)?.messages;
  const dividerMessage = history ? history.firstUnread : firstUnread;
  const newCount = chat && history ? Math.max(0, chat.received - history.chat.received) : 0;
  useLayoutEffect(() => {
    const list = scrollable.current;
    if (!list || !chat || history) {
      return;
    }
    const requested = jumpToMessage.current;
    jumpToMessage.current = null;
    const target = requested
      ? Array.from(list.querySelectorAll<HTMLElement>('[data-chat-message-id]'))
        .find(row => row.dataset.chatMessageId === requested)
      : opened.current ? null : unreadDivider.current;
    opened.current = true;
    if (target) {
      list.scrollTop += target.getBoundingClientRect().top - list.getBoundingClientRect().top;
      if (!isAtChatEnd(list)) {
        setHeldHistory({ chat, firstUnread });
      }
    } else {
      list.scrollTop = list.scrollHeight;
    }
    onRead(chat.visit, chat.received);
  }, [chat, firstUnread, history, onRead]);
  useLayoutEffect(() => {
    const sent = submitted.current;
    if (chat?.status === 'sent' && sent !== null) {
      setDraft(current => current.trim() === sent ? '' : current);
    }
    if (chat?.status !== 'sending') {
      submitted.current = null;
    }
  }, [chat?.status]);

  const send = () => {
    if (chat && !pending && text && text.length <= CHAT_LIMIT) {
      submitted.current = text;
      onSend(chat.node, text);
    }
  };
  const handleScroll = () => {
    const list = scrollable.current;
    if (!list || !chat) {
      return;
    }
    if (isAtChatEnd(list)) {
      setHeldHistory(null);
    } else if (!history) {
      setHeldHistory({ chat, firstUnread });
    }
  };
  const showNewMessages = () => {
    if (chat && history) {
      jumpToMessage.current = firstUnreadMessage(chat, history.chat.received, chat.received);
      setHeldHistory(null);
    }
  };
  const unavailable = state === 'active' ? 'Подключаемся к чату…' : CHAT_STATUS[state ?? ''] ?? 'Войдите в сеть, чтобы открыть чат узла.';
  return (
    <>
      <Stack.Item grow position="relative">
        <Section
          fill
          scrollable
          scrollableRef={scrollable}
          onScroll={handleScroll}
          title={chat?.channel ? 'Общий канал сети' : chat ? `Чат узла ${chat.node}` : 'Чат узла'}
          buttons={(
            <>
              <Button icon={chat?.channel ? 'map-marker-alt' : 'satellite-dish'} onClick={onChannel}>
                {chat?.channel ? 'К узлу' : 'Канал'}
              </Button>
              <Button icon="list" onClick={onJournal}>Журнал</Button>
            </>
          )}>
          {!chat && <Box color="label">{unavailable}</Box>}
          {messages?.length === 0 && <Box color="label">Сообщений пока нет.</Box>}
          {messages?.map(message => (
            <Box key={message.id} data-chat-message-id={message.id} mb={0.5} style={{ overflowWrap: 'anywhere' }}>
              {message.id === dividerMessage && (
                <div ref={unreadDivider} role="separator" aria-label="Новые сообщения">
                  <Box bold color="average" my={0.5} pt={0.5} style={{ borderTop: '1px solid currentColor' }}>
                    Новые сообщения
                  </Box>
                </div>
              )}
              <Box color={message.own ? 'good' : 'label'}>{message.own ? 'Вы' : message.sender}</Box>
              {message.text}
            </Box>
          ))}
        </Section>
        <Box position="absolute" bottom={0.75} right={0.75} style={{ zIndex: 1 }} aria-live="polite">
          {newCount > 0 && (
            <Button
              icon="arrow-down"
              color="average"
              aria-label={`К новым сообщениям, непрочитанных ${newCount}`}
              onClick={showNewMessages}>
              К новым сообщениям · {newCount > 99 ? '99+' : newCount}
            </Button>
          )}
        </Box>
      </Stack.Item>
      {!!chat && (
        <Stack.Item>
          <Section>
            <Stack align="center">
              <Stack.Item grow>
                <div className="Input Input--fluid">
                  <div className="Input__baseline" aria-hidden="true">.</div>
                  <input
                    className="Input__input"
                    aria-label="Сообщение в чат узла"
                    autoComplete="off"
                    maxLength={CHAT_LIMIT}
                    placeholder={chat?.channel ? 'Сообщение в общий канал' : 'Сообщение на узел'}
                    value={draft}
                    onChange={event => setDraft(event.currentTarget.value)}
                    onKeyDown={event => {
                      if (event.key === 'Enter' && !event.nativeEvent.isComposing) {
                        event.preventDefault();
                        send();
                      }
                    }} />
                </div>
              </Stack.Item>
              <Stack.Item>
                <Button icon="paper-plane" disabled={pending || !text} onClick={send}>Отправить</Button>
              </Stack.Item>
            </Stack>
            {!!chat.status && CHAT_STATUS[chat.status] && (
              <Box mt={0.5} color={pending || chat.status === 'sent' ? 'label' : 'average'}>{CHAT_STATUS[chat.status]}</Box>
            )}
          </Section>
        </Stack.Item>
      )}
    </>
  );
};

/**
 * P12.4 · the player's network window: what the operator knows (stale items drawn muted), its presence,
 * and the presence commands. Every button is a network command; the window draws what came back.
 */
const COLOURS = ['#8ab4f8', '#81c995', '#fdd663', '#f28b82', '#c58af9', '#78d9ec', '#f6aea9', '#b7b7b7'];

const SUMMON_GOALS: Record<string, string> = {
  Курьер: 'courier',
  Инженер: 'engineer',
  Страж: 'sentinel',
  Наблюдатель: 'watcher',
  Архивист: 'archivist',
};

const GOAL_TEXT: Record<string, string> = {
  sentinel: 'страж',
  watcher: 'наблюдатель',
  archivist: 'архивист',
  courier: 'курьер',
  intruder: 'вторженец',
  saboteur: 'диверсант',
  engineer: 'инженер',
};

const LIFE_KIND: Record<string, string> = {
  spawn: 'появление',
  move: 'переход',
  watch: 'наблюдение',
  task: 'задача',
  persona: 'личность',
};

/** P13: the operator's identity, the dive switch and the life of the network. */
const NetworkLifePanel = (props: {
  persona: Persona | null;
  bots: LifeBot[];
  activity: LifeEvent[];
  operators: LifeOperator[];
  incidents: LifeIncident[];
  immersed: BooleanLike;
  enabled: BooleanLike;
  onPersona: (name: string, signature: string, status: string, colour: number) => void;
  onImmerse: () => void;
  onSurface: () => void;
  onSummon: (goal: string) => void;
}) => {
  const { persona, bots, activity, operators, incidents, immersed, enabled, onPersona, onImmerse, onSurface, onSummon } = props;
  const [summonLabel, setSummonLabel] = useState('Курьер');
  const [name, setName] = useState(persona?.name ?? '');
  const [signature, setSignature] = useState(persona?.signature ?? '');
  const [status, setStatus] = useState(persona?.status ?? '');
  const [colour, setColour] = useState(persona?.colour ?? 0);
  return (
    <Section
      title="Личность и сеть"
      buttons={(
        <Button
          icon={immersed ? 'sign-out-alt' : 'brain'}
          color={immersed ? 'bad' : 'good'}
          disabled={!enabled || immersed === 1}
          tooltip={enabled ? undefined : 'Погружение выключено на этом раунде'}
          onClick={onImmerse}>
          {immersed ? 'Выйти' : 'Погрузиться'}
        </Button>
      )}>
      <LabeledList>
        <LabeledList.Item label="Позывной">
          <Input
            value={name}
            maxLength={24}
            width="12rem"
            placeholder="до 24 символов"
            onChange={(e, value) => setName(value)} />
        </LabeledList.Item>
        <LabeledList.Item label="Знак">
          <Input
            value={signature}
            maxLength={4}
            width="5rem"
            onChange={(e, value) => setSignature(value)} />
        </LabeledList.Item>
        <LabeledList.Item label="Должность">
          <Box color="label">{persona?.role || 'определится при входе в сеть'}</Box>
        </LabeledList.Item>
        <LabeledList.Item label="Статус">
          <Input
            value={status}
            maxLength={32}
            width="20rem"
            placeholder="строка о себе, до 32 символов"
            onChange={(e, value) => setStatus(value)} />
        </LabeledList.Item>
        <LabeledList.Item label="Цвет">
          <Stack>
            {COLOURS.map((entry, index) => (
              <Stack.Item key={entry}>
                <Button
                  selected={colour === index}
                  color="transparent"
                  style={{ backgroundColor: entry, width: '1.1rem', minWidth: '1.1rem', height: '1.1rem' }}
                  tooltip={`Цвет ${index}`}
                  onClick={() => setColour(index)} />
              </Stack.Item>
            ))}
          </Stack>
        </LabeledList.Item>
        <LabeledList.Item label="Сохранить">
          <Button icon="save" onClick={() => onPersona(name, signature, status, colour)}>
            Применить
          </Button>
        </LabeledList.Item>
        <LabeledList.Item label="Вызов агента">
          <Dropdown
            width="9rem"
            selected={summonLabel}
            options={['Курьер', 'Инженер', 'Страж', 'Наблюдатель', 'Архивист']}
            onSelected={value => setSummonLabel(value)} />
          <Button
            ml={0.5}
            icon="user-plus"
            disabled={!enabled}
            tooltip={enabled ? 'Вызвать сетевого агента к вашему узлу' : 'Слой сетевой жизни выключен'}
            onClick={() => onSummon(SUMMON_GOALS[summonLabel] ?? 'courier')}>
            Вызвать
          </Button>
        </LabeledList.Item>
      </LabeledList>
      <Box mt={0.5} color="label">
        Агенты в сети: {bots.length === 0 ? 'не обнаружены' : bots.map(bot => (
          `${bot.signature || '?'} ${bot.name} (${GOAL_TEXT[bot.goal] ?? bot.goal})`
        )).join(', ')}
      </Box>
      <Box mt={0.5} color="label">
        Операторы в сети: {operators.length === 0 ? 'только вы' : operators.map(operator => (
          `${operator.role ? `${operator.role}: ` : ''}${operator.name || 'оператор'}${operator.status ? ` — ${operator.status}` : ''}`
        )).join(', ')}
      </Box>
      <Box mt={0.5} color="label" fontSize="0.9em">
        Легенда: ■ АПЦ · ● узел · ◯ оператор · ◆ агент · гало вокруг — недавняя активность
      </Box>
      <Section title="Происшествия сети" mt={0.5} scrollable height="6rem">
        {incidents.length === 0 && <Box color="label">Сеть спокойна.</Box>}
        {incidents.slice(-8).reverse().map((incident, index) => (
          <Box key={`${incident.at}-${index}`} color={incident.kind === 'sabotage' || incident.kind === 'intrusion' ? 'average' : 'label'}>
            {`${String(Math.floor(incident.at / 60)).padStart(2, '0')}:${String(incident.at % 60).padStart(2, '0')}`}
            {' · '}
            {incident.text}
          </Box>
        ))}
      </Section>
      <Section title="Активность сети" mt={0.5} scrollable height="8rem">
        {activity.length === 0 && <Box color="label">Пока ничего не происходит.</Box>}
        {[...activity].reverse().map(event => (
          <Box key={event.seq}>
            <Box as="span" color="label">[{LIFE_KIND[event.kind] ?? event.kind}] </Box>
            {event.text}
          </Box>
        ))}
      </Section>
    </Section>
  );
};

const HackPanel = (props: { hack: HackState | null; selected: string | null }) => {
  const { act } = useBackend();
  const [answer, setAnswer] = useState('');
  const hack = props.hack;
  const actRef = useRef(act);
  actRef.current = act;
  useEffect(() => {
    // One-shot load: `act` may get a new identity on every backend update, and re-running this
    // effect on each render would hammer the Host with key queries for no reason.
    actRef.current('hack_keys');
  }, []);
  const keys = hack?.keys ?? [];
  return (
    <Section title="Взлом и доступ">
      <LabeledList>
        <LabeledList.Item label="Анонимность">
          <Button
            icon={hack?.masked ? 'user-secret' : 'user'}
            selected={!!hack?.masked}
            onClick={() => act('hack_mask')}>
            {hack?.masked ? 'личность скрыта' : 'личность видна'}
          </Button>
        </LabeledList.Item>
        <LabeledList.Item label="Цель">
          <Box inline color={props.selected ? 'label' : 'average'}>
            {props.selected ? `узел ${props.selected}` : 'выберите узел на карте'}
          </Box>
          <Button
            ml={1}
            icon="user-secret"
            disabled={!props.selected}
            onClick={() => act('hack_start', { node: props.selected })}>
            Взломать
          </Button>
        </LabeledList.Item>
        {!!hack?.code && (
          <LabeledList.Item label="Код взлома">
            <Box inline bold color="average">{hack.code}</Box>
            <Input
              ml={1}
              width="8rem"
              value={answer}
              maxLength={16}
              placeholder="код из окна"
              onChange={(event, value) => setAnswer(value)} />
            <Button
              ml={0.5}
              icon="check"
              disabled={!answer.trim()}
              onClick={() => {
                act('hack_answer', { code: answer });
                setAnswer('');
              }}>
              Подтвердить
            </Button>
          </LabeledList.Item>
        )}
        <LabeledList.Item label="Украденные доступы">
          {keys.length === 0 && <Box color="label">нет</Box>}
          {keys.map(key => (
            <Box key={key.node} mb={0.25}>
              <Box inline>{key.label}</Box>
              <Box inline color="label" ml={1}>{key.ttl} с</Box>
              <Button
                ml={1}
                icon="bolt"
                disabled={!key.node}
                onClick={() => act('hack_use', { node: key.node })}>
                Питание
              </Button>
            </Box>
          ))}
        </LabeledList.Item>
      </LabeledList>
      <Box mt={0.5} color="label" fontSize="0.9em">
        Взлом: код виден только вам и живёт 15 секунд; провал поднимает тревогу и перезарядку.
      </Box>
    </Section>
  );
};
// TODO(netdm-ui): split this stateful screen into feature panels and dedicated hooks.
// eslint-disable-next-line complexity
export const NetdmSpace = () => {
  const { act, data } = useBackend<Data>();
  const view = useMemo(
    () => parseView({ nodes: data.nodes, edges: data.edges, down: data.down }),
    [data.nodes, data.edges, data.down],
  );
  const [selected, setSelected] = useState<string | null>(null);
  const [failure, setFailure] = useState<string | null>(null);
  const [radius, setRadius] = useState(3);
  const [fitRequest, setFitRequest] = useState(0);
  const [focusRequest, setFocusRequest] = useState(0);
  const [showMapLegend, setShowMapLegend] = useState(false);
  const [line, setLine] = useState('');
  const [advanced, setAdvanced] = useState(false);
  const [chatOpening, setChatOpening] = useState<ChatOpening | null>(null);
  const [readChat, setReadChat] = useState<ChatProgress | null>(null);
  const showChat = chatOpening !== null;
  const presence = data.presence;
  const life = data.life ?? { bots: [], activity: [], operators: [] };
  const persona = data.persona ?? presence?.persona ?? null;
  const immersed = !!data.immersed;
  const activity = useMemo(() => countActivityNodes(life.activity), [life.activity]);
  const agents = useMemo(() => life.bots.map(bot => ({ node: bot.node, goal: bot.goal, label: bot.name })), [life.bots]);
  const operators: SceneOperator[] = useMemo(() => (life.operators ?? []).map(operator => ({
    node: operator.node,
    label: operator.name
      ? `${operator.role ? `${operator.role}: ` : ''}${operator.name}`
      : 'оператор',
    colour: operator.colour,
  })), [life.operators]);
  const watch = data.alarmWatch;
  const machineCommand = data.machineCommand;
  const machinePending = machineCommand?.status === 'sending' || machineCommand?.status === 'sent';
  const inside = !!presence?.presence && presence.state !== 'ended';
  const active = inside && presence.state === 'active';
  const chat = active ? data.chat ?? null : null;
  const visit = chat?.visit;
  const received = chat?.received ?? 0;
  const read = readChat && readChat.visit === visit ? readChat.received : 0;
  const unread = !showChat && visit ? Math.max(0, received - read) : 0;
  const openingSnapshot = chatOpening?.snapshot ?? chat;
  const openingRead = chatOpening?.previousRead;
  const readAtOpening = openingRead && openingRead.visit === visit ? openingRead.received : 0;
  const firstUnread = chatOpening && chat && openingSnapshot && openingSnapshot.visit === chat.visit
    ? firstUnreadMessage(chat, readAtOpening, openingSnapshot.received)
    : null;
  const markChatRead = useCallback((visit: string, received: number) => {
    setReadChat(previous => (
      previous?.visit === visit && previous.received >= received ? previous : { visit, received }
    ));
  }, []);
  useLayoutEffect(() => {
    if (chatOpening && !chatOpening.snapshot && visit) {
      setChatOpening({ ...chatOpening, snapshot: { visit, received } });
    }
  }, [chatOpening, visit, received]);
  const canResume = inside && presence.state === 'suspended' && presence.reason === 'operator_away';
  const canScan = !inside || active;
  const shown = selected ?? data.hostNode ?? null;
  const selectedTravel = useMemo(
    () => nodeTravelChoice(view, shown, data.hostNode, data.services),
    [view, shown, data.hostNode, data.services],
  );
  const otherPresences = data.otherPresences;
  const moving = presence?.state === 'moving';
  const foundTarget = active && data.routePreview ? data.services.find(service => (
    service.type === 'network.shell' && service.instance === data.routePreview?.target && service.node === shown
  )) : undefined;
  const routePending = active && data.routePreview?.status === 'pending';
  const preview = foundTarget || routePending ? data.routePreview : null;
  const route = useMemo<SceneRoute | null>(() => {
    if (moving && presence?.route?.length) {
      return { moving: true, nodes: presence.route, radioLegs: presence.radioLegs ?? [] };
    }
    if (preview?.status === 'ready' && preview.nodes?.length) {
      return { moving: false, nodes: preview.nodes, radioLegs: preview.radioLegs ?? [] };
    }
    if (presence?.breakFrom && presence.breakTo) {
      return {
        moving: false,
        broken: true,
        nodes: [presence.breakFrom, presence.breakTo],
        radioLegs: presence.breakKind === 'radio' ? [1] : [],
      };
    }
    return null;
  }, [moving, presence?.route, presence?.radioLegs, presence?.breakFrom, presence?.breakTo, presence?.breakKind, preview]);
  const nearby = useMemo(
    () => nearbyDestinations(view, data.hostNode, data.services),
    [view, data.hostNode, data.services],
  );
  const targetNode = foundTarget && view.nodes.get(foundTarget.node);
  const canMove = active && !!foundTarget && !!targetNode && !foundTarget.stale && !isOffline(targetNode.flags);
  const reason = presence?.reason ? REASON_TEXT[presence.reason] ?? presence.reason : null;
  // Camera movements never imply a presence move. Only server-authorized move can do that.
  const focusHome = useCallback(() => {
    if (data.hostNode && view.nodes.has(data.hostNode)) {
      setSelected(data.hostNode);
      setFocusRequest(request => request + 1);
    }
  }, [data.hostNode, view]);
  useEffect(() => {
    const keyboard = (event: KeyboardEvent) => {
      if (!inside || event.altKey || event.ctrlKey || event.metaKey || event.repeat) {
        return;
      }
      const target = event.target as HTMLElement | null;
      if (target?.closest('input, textarea, select, button, [role="button"], [contenteditable="true"]')) {
        return;
      }
      // The chat and shell are independent input surfaces; shortcuts work only
      // when the player is navigating the main network canvas.
      if (showChat) {
        return;
      }
      if (event.key.toLowerCase() === 'f') {
        event.preventDefault();
        focusHome();
      } else if (event.key === 'Escape') {
        setSelected(null);
      } else if (event.key.toLowerCase() === 'g' && active && !moving && !routePending &&
                 selected && selectedTravel.state === 'ready' && selectedTravel.instance) {
        event.preventDefault();
        act('preview_move', { to: selectedTravel.instance });
      } else if (event.key === 'Enter' && canMove && !moving &&
                 isSelectedPreview(selectedTravel, preview) && preview?.target) {
        // Enter only confirms a route returned by Host for this exact selected
        // destination; the server will still recheck everything during move.
        event.preventDefault();
        act('move', { to: preview.target });
      }
    };
    window.addEventListener('keydown', keyboard);
    return () => window.removeEventListener('keydown', keyboard);
  }, [inside, showChat, focusHome, active, moving, routePending, selected,
    selectedTravel, canMove, preview, act]);
  const send = () => {
    const trimmed = line.trim();
    if (active && trimmed.length > 0 && trimmed.length <= 1024) {
      act('act', { line: trimmed });
      setLine('');
    }
  };
  const trace = (id: string) => {
    if (active && view.nodes.has(id) && /^\d{1,20}$/.test(id)) {
      act('act', { line: `trace ${id} | select state hops radioHops ticks` });
    }
  };

  return (
    <Window width={inside ? 1120 : 860} height={inside ? 720 : 600} title={`Сеть: ${data.title}`}>
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
                        ? ` → ${presence!.to}`
                        : ` на ${presence!.host}`}
                      {inside && presence?.state !== 'moving' && view.nodes.has(data.hostNode ?? '') && (
                        <Box inline ml={0.5} color="#55e7d0" title="Ваше присутствие на карте">○</Box>
                      )}
                      {advanced && ` · поколение ${presence!.generation ?? 1}`}
                      {reason && ` · ${reason}`}
                    </Box>
                  ) : (
                    <Box color="label">
                      Вы не в сети.{reason && ` Последнее присутствие: ${reason}.`}
                    </Box>
                  )}
                </Stack.Item>
                {canResume && (
                  <Stack.Item>
                    <Button icon="play" onClick={() => act('enter')}>Продолжить</Button>
                  </Stack.Item>
                )}
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
                  <Button icon="satellite-dish" disabled={!canScan} onClick={() => act('scan', { radius })}>Сканировать</Button>
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
                {inside && !!data.hostNode && view.nodes.has(data.hostNode) && (
                  <Stack.Item>
                    <Button icon="crosshairs" onClick={focusHome} tooltip="Показать своё местоположение (F)">
                      Я здесь · F
                    </Button>
                  </Stack.Item>
                )}
                {!failure && view.nodes.size > 0 && (
                  <Stack.Item>
                    <Button icon="expand" onClick={() => setFitRequest(current => current + 1)}>Вся карта</Button>
                  </Stack.Item>
                )}
              </Stack>
            </Section>
          </Stack.Item>
          <Stack.Item grow>
            <Stack fill>
              <Stack.Item grow position="relative">
                {view.nodes.size === 0 ? (
                  <Section fill>
                    <Box color="label">Вы пока ничего не знаете о сети. Сканируйте, чтобы увидеть окрестность.</Box>
                  </Section>
                ) : failure ? (
                  <FallbackList
                    view={view}
                    reason={failure}
                    otherPresences={otherPresences}
                    activity={activity}
                    agents={agents}
                    operators={operators}
                    onSelect={setSelected}
                    onRetry={() => setFailure(null)} />
                ) : (
                  <div style={{ position: 'relative', width: '100%', height: '100%' }}>
                  <TopologyCanvas
                    view={view}
                    levelKey={String(data.z)}
                    selected={selected}
                    presenceNode={inside && presence?.state !== 'moving' ? data.hostNode : null}
                    otherPresences={otherPresences}
                    activity={activity}
                    agents={agents}
                    operators={operators}
                    route={route}
                    filters={FILTERS}
                    fitRequest={fitRequest}
                    focusRequest={focusRequest}
                    focusTarget={data.hostNode}
                    onSelect={setSelected}
                    onFailure={setFailure}
                    onReport={() => undefined} />
                    <MapChrome
                      level={data.z}
                      nodeCount={view.nodes.size}
                      linkCount={view.links.size}
                      selected={shown ? view.nodes.get(shown) : undefined}
                      view={view}
                      showLegend={showMapLegend}
                      onToggleLegend={() => setShowMapLegend(value => !value)} />
                  </div>
                )}
                {!failure && view.nodes.size > 0 && otherPresences && Object.keys(otherPresences).length > 0 && (
                  <Box
                    position="absolute"
                    bottom={0.5}
                    left={0.5}
                    px={0.5}
                    py={0.25}
                    color={OTHER_PRESENCE_COLOR}
                    backgroundColor="#101217"
                    style={{ pointerEvents: 'none' }}>
                    ◆ Чужое присутствие
                  </Box>
                )}
              </Stack.Item>
              <Stack.Item basis={inside ? '340px' : '300px'}>
                <Stack fill vertical>
                  {(moving || preview || presence?.breakKind) && (
                    <Stack.Item>
                      <RoutePanel
                        preview={preview}
                        presence={presence}
                        canMove={canMove}
                        onMove={target => act('move', { to: target })}
                        onRetry={target => act('preview_move', { to: target })}
                        onClear={() => act('clear_route_preview')}
                        onAbort={() => act('abort_move')} />
                    </Stack.Item>
                  )}
                  {inside && (
                    <Stack.Item>
                      <NearbyMovementPanel
                        destinations={nearby}
                        active={active}
                        moving={moving}
                        pending={routePending}
                        onPreview={destination => {
                          setSelected(destination.node);
                          act('preview_move', { to: destination.instance });
                        }} />
                    </Stack.Item>
                  )}
                  <Stack.Item>
                    <NodePanel
                      view={view}
                      id={shown}
                      services={data.services}
                      travel={selectedTravel}
                      otherPresences={shown ? otherPresences?.[shown] ?? 0 : 0}
                      active={active}
                      alarmPending={!!data.alarmPending}
                      machinePending={machinePending}
                      routePending={routePending}
                      watchedAlarm={watch?.instance ?? null}
                      onPreview={instance => act('preview_move', { to: instance })}
                      onReadAlarm={instance => act('read_alarm', { instance })}
                      onWatchAlarm={instance => act('watch_alarm', { instance })}
                      onSetAlarm={(instance, enabled) => act('machine_alert', { instance, enabled: enabled ? 1 : 0 })}
                      onTrace={trace} />
                  </Stack.Item>
                  {!!presence?.threat && (
                    <Stack.Item>
                      <NoticeBox danger>
                        Враждебный агент на узле: {presence.threat}
                        <Button ml={1} icon="user-slash" onClick={() => act('banish')}>
                          Выгнать
                        </Button>
                      </NoticeBox>
                    </Stack.Item>
                  )}
                  {immersed && (
                    <Stack.Item>
                      <NoticeBox danger>
                        ПОГРУЖЕНИЕ: тело оставлено у точки доступа.
                        {!!data.immersedSeconds && ` · в сети ${Math.floor((data.immersedSeconds ?? 0) / 60)} мин ${(data.immersedSeconds ?? 0) % 60} с`}
                        {!!data.immersionReason && ` Причина выхода: ${data.immersionReason}`}
                        <Button ml={1} icon="sign-out-alt" onClick={() => act('surface')}>
                          Выйти
                        </Button>
                      </NoticeBox>
                    </Stack.Item>
                  )}
                  <Stack.Item>
                    <NetworkLifePanel
                      persona={persona}
                      bots={life.bots}
                      activity={life.activity}
                      operators={life.operators ?? []}
                      incidents={data.incidents ?? []}
                      immersed={data.immersed}
                      enabled={data.immersionEnabled}
                      onPersona={(name, signature, status, colour) => act('persona', { name, signature, status, colour })}
                      onImmerse={() => act('immerse')}
                      onSurface={() => act('surface')}
                      onSummon={goal => act('call_agent', { goal })} />
                  </Stack.Item>
                  <Stack.Item>
                    <HackPanel hack={data.hack ?? null} selected={selected} />
                  </Stack.Item>
                  {machineCommand && (
                    <Stack.Item><MachineCommandPanel command={machineCommand} /></Stack.Item>
                  )}
                  {watch && (
                    <Stack.Item>
                      <AlarmWatchPanel
                        watch={watch}
                        onSelect={() => {
                          setSelected(watch.node);
                          if (watch.z !== null && watch.z !== data.z) {
                            act('level', { z: watch.z });
                          }
                        }}
                        onStop={() => act('stop_alarm_watch')} />
                    </Stack.Item>
                  )}
                  {showChat ? (
                    <NodeChatPanel
                      key={chat?.visit ?? 'connecting'}
                      chat={chat}
                      state={presence?.state}
                      firstUnread={firstUnread}
                      onJournal={() => setChatOpening(null)}
                      onRead={markChatRead}
                      onSend={(node, text) => act('send_chat', { node, text })}
    onChannel={() => act('chat_channel')} />
                  ) : (
                    <Stack.Item grow>
                      <Section
                        fill
                        scrollable
                        title="Журнал"
                        buttons={(
                          <>
                            <Button
                              icon="comments"
                              color={unread ? 'average' : undefined}
                              aria-label={unread ? `Чат узла, непрочитанных сообщений ${unread}` : 'Чат узла'}
                              onClick={() => setChatOpening({ previousRead: readChat, snapshot: visit ? { visit, received } : null })}>
                              Чат узла
                              {unread > 0 && <Box as="span" bold ml={0.5}>{unread > 99 ? '99+' : unread}</Box>}
                            </Button>
                            <Button icon="terminal" selected={advanced} onClick={() => setAdvanced(current => !current)}>Команды</Button>
                          </>
                        )}>
                        {data.log.length === 0 && <Box color="label">Пусто.</Box>}
                        {[...data.log].reverse().map((entry, index) => (
                          <Box key={index}>{entry}</Box>
                        ))}
                      </Section>
                    </Stack.Item>
                  )}
                  {!showChat && advanced && (
                    <Stack.Item>
                      <ActionBox
                        line={line}
                        enabled={active}
                        dynamic={{
                          instances: data.services.map(service => service.instance),
                          nodes: [...view.nodes.keys()],
                          types: [...new Set(data.services.map(service => service.type))],
                        }}
                        onLine={setLine}
                        onSend={send} />
                    </Stack.Item>
                  )}
                </Stack>
              </Stack.Item>
            </Stack>
          </Stack.Item>
        </Stack>
      </Window.Content>
    </Window>
  );
};