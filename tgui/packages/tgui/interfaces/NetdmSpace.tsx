import { BooleanLike } from 'common/react';
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';

import { useBackend } from '../backend';
import { Box, Button, Icon, NoticeBox, ProgressBar, Section, Stack, Table } from '../components';
import { Window } from '../layouts';
import { HackState, NetdmBreach } from './NetdmBreach';
import { NetdmDeliveryActivity } from './NetdmDelivery';
import { DeviceEntry } from './NetdmDeviceState';
import { isSelectedPreview, NodeTravelChoice, nodeTravelChoice } from './netdmNodeTravel';
import { knownAdjacentNodes, NearbyDestination, nearbyDestinations, NearbyNode } from './netdmPresenceNavigation';
import { NetdmServiceActions } from './NetdmServiceActions';
import { safeServiceIdentifier } from './NetdmServiceSchema';
import { SHELL_COMMANDS, ShellDynamicPool, tabComplete } from './netdmShell';
import { NetdmSpaceDock, SpaceTab } from './NetdmSpaceDock';
import { NetdmTerminalContent, NetdmTerminalData, NetdmTerminalEvents } from './NetdmTerminal';
import { TopologyCanvas } from './NetdmTopology';
import { MapChrome } from './NetdmTopology/MapChrome';
import { countActivityNodes, FLAG_APC, FLAG_UNPOWERED, isOffline, parseView, View } from './NetdmTopology/model';
import { NodePresenceCounts, SceneFilters, SceneOperator, SceneRoute, SceneSignal } from './NetdmTopology/scene';

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

type DoorAction = 'open' | 'close' | 'bolt' | 'unbolt';
type DoorPanelState = { opened: BooleanLike; bolted: BooleanLike };

type Service = {
  instance: string; type: string; node: string; stale: BooleanLike;
  canControlAlarm?: BooleanLike; cameraName?: string | null;
  doorPanel?: DoorPanelState | null;
};

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
  kind?: 'door' | 'alarm';
  enabled?: BooleanLike;
  status: 'sending' | 'sent' | 'applied' | 'rejected' | 'not_delivered' | 'no_receipt' | 'unknown';
  operation?: string;
  reason?: string;
  source?: string;
  zoneAlarm?: BooleanLike;
  sourceActive?: BooleanLike;
  doorAction?: DoorAction | null;
  doorOpen?: BooleanLike;
  doorBolted?: BooleanLike;
  changed?: BooleanLike;
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
  entityRole?: BooleanLike;
  terminal?: NetdmTerminalData | null;
  z: number;
  levels: number[];
  nodes: unknown[];
  edges: unknown[];
  down: unknown[];
  services: Service[];
  actionEntries?: DeviceEntry[];
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
const EMPTY_ACTIONS: DeviceEntry[] = [];
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

const DOOR_ACTIONS = {
  open: { icon: 'door-open', label: 'Открыть шлюз', confirm: 'Открыть шлюз?' },
  close: { icon: 'door-closed', label: 'Закрыть шлюз', confirm: 'Закрыть шлюз?' },
  bolt: { icon: 'lock', label: 'Опустить болты', confirm: 'Опустить болты?' },
  unbolt: { icon: 'lock-open', label: 'Поднять болты', confirm: 'Поднять болты?' },
};

const DOOR_STATUS: Partial<Record<MachineCommand['status'], string>> = {
  sent: 'Ожидаем выполнения шлюзом…',
  applied: 'Шлюз подтвердил выполнение',
  not_delivered: 'Команда не дошла до шлюза',
  no_receipt: 'Квитанция от шлюза не пришла. Исход команды неизвестен.',
};

const DOOR_REASON: Record<string, string> = {
  access_denied: 'У оператора нет доступа к панели шлюза.',
  door_blocked: 'Текущее состояние шлюза мешает выполнить команду.',
  door_gone: 'Шлюз больше недоступен в сети.',
  denied: 'Требуется доступ к панели шлюза.',
  forbidden: 'Требуется доступ к панели шлюза.',
  offline: 'Шлюз отключён.',
  unreachable: 'Маршрут до шлюза недоступен.',
  invalid_route: 'Маршрут до шлюза недоступен.',
};

const describeDoorState = (opened: BooleanLike, bolted: BooleanLike) =>
  `${opened ? 'Шлюз открыт' : 'Шлюз закрыт'} · ${bolted ? 'болты опущены' : 'болты подняты'}`;

const DoorPanel = ({ state, disabled, onAction }: {
  state: DoorPanelState; disabled: boolean; onAction: (command: DoorAction) => void;
}) => {
  const actions: DoorAction[] = [state.opened ? 'close' : 'open', state.bolted ? 'unbolt' : 'bolt'];
  return (
    <details className="NetdmDock__disclosure">
      <summary>Панель шлюза</summary>
      <Box color="label">{describeDoorState(state.opened, state.bolted)}</Box>
      <div className="NetdmDock__actions">
        {actions.map(command => {
          const { icon, label, confirm } = DOOR_ACTIONS[command];
          return (
            <Button.Confirm key={command} icon={icon} content={label} confirmContent={confirm}
              disabled={disabled} onClick={() => onAction(command)} />
          );
        })}
      </div>
    </details>
  );
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
/** Actor-scoped context; selecting a service never sends a network command. */
const NodePanel = (props: {
  view: View; id: string | null; services: Service[]; entries: DeviceEntry[]; activity: LifeEvent[];
  otherPresences: number; travel: NodeTravelChoice; active: boolean; alarmPending: boolean;
  machinePending: boolean; routePending: boolean; watchedAlarm: string | null; hack?: HackState | null;
  selectedService?: string; onSelectService: (instance: string) => void;
  onPreview: (instance: string) => void; onTrace: (id: string) => void;
  onPrepareTerminal?: (line: string) => void;
  onWatchAlarm: (instance: string) => void; onReadAlarm: (instance: string) => void;
  onSetAlarm: (instance: string, enabled: boolean) => void; onCommand: (line: string) => void;
  onHack: (node: string) => void; onHackAnswer: (answer: string) => void; onHackUse: (node: string) => void;
  onSelectCamera: (instance: string) => void;
  onDoorAction: (instance: string, command: DoorAction) => void;
}) => {
  const { id, view, services, entries, activity, otherPresences, travel, active, alarmPending,
    machinePending, routePending, watchedAlarm, onPreview, onTrace, onPrepareTerminal, onWatchAlarm, onReadAlarm,
    onSetAlarm, onCommand, hack, onHack, onHackAnswer, onHackUse, onSelectCamera,
    onDoorAction, selectedService, onSelectService } = props;
  const node = id ? view.nodes.get(id) : undefined;
  if (!id || !node) {
    return <Box className="NetdmDock__empty">Выберите узел на карте.</Box>;
  }
  const here = services.filter(service => service.node === id);
  const current = here.find(service => service.instance === selectedService) ??
    here.find(service => service.type !== 'network.shell') ?? here[0] ?? null;
  const stale = isOffline(node.flags);
  const disabled = !active || stale || !!current?.stale;
  const recent = activity.filter(item => item.node === id).slice(-3).reverse();
  const travelHint = {
    here: 'Вы на этом узле',
    unknown: 'Узел ещё не обнаружен',
    offline: 'Узел недоступен',
    no_shell: 'Без точки входа',
    stale: 'Обновите карту для перехода',
    ready: 'Доступен переход',
  }[travel.state];
  const serviceName = (service: Service) => ({
    'atmos.alarm': 'Панель атмосферы',
    'atmos.telemetry': 'Датчик атмосферы',
    'camera.access': 'Камера',
    'machine.control': 'Управление питанием',
    'machine.door': 'Шлюз',
    'network.shell': 'Оболочка узла',
    'pda.messenger': 'Сервер сообщений',
    'research.server': 'Сервер исследований',
  }[service.type] ?? service.type.replace(/\./g, ' '));
  const serviceActions = current && (
    <NetdmServiceActions key={current.instance} instance={current.instance}
      type={current.type} entries={entries} disabled={disabled} onCommand={onCommand} />
  );
  const serviceType = current?.type;
  const doorPanel = serviceType === 'machine.door' ? current?.doorPanel : null;
  const hasDedicatedControls = serviceType === 'camera.access' || serviceType === 'atmos.alarm' || !!doorPanel;

  return (
    <div className="NetdmNode NetdmSpaceContext">
      <div className="NetdmNode__overview">
        <h3>{current ? current.cameraName || serviceName(current) : node.flags & FLAG_APC ? 'АПЦ' : 'Устройство'}</h3>
        <div className="NetdmNode__status" data-state={stale ? 'stale' : travel.state}>
          {stale ? 'Сведения устарели' : travelHint}
          {otherPresences > 0 && <span title="Другие присутствия">◆ {otherPresences}</span>}
        </div>
        {travel.state === 'ready' && (
          <div className="NetdmDock__actions">
            <Button icon="route" disabled={!active || routePending}
              onClick={() => travel.instance && onPreview(travel.instance)}>Проверить переход
            </Button>
          </div>
        )}
      </div>
      {current ? (
        <div className="NetdmNode__service">
          {here.length > 1 && (
            <label className="NetdmDock__field">
              <span>Сервис</span>
              <select value={current.instance} onChange={event => onSelectService(event.currentTarget.value)}>
                {here.map(service => (
                  <option key={service.instance} value={service.instance}>
                    {service.cameraName || serviceName(service)}{service.stale ? ' · устарел' : ''}
                  </option>
                ))}
              </select>
            </label>
          )}
          {!!current.cameraName && (
            <div className="NetdmDock__actions">
              <Button icon="video" disabled={stale || !!current.stale}
                onClick={() => onSelectCamera(current.instance)}>Подключить на консоли
              </Button>
            </div>
          )}
          {current.type === 'camera.access' && !current.cameraName && (
            <Box color="label">Изображение доступно на охранной консоли с доступом к этой камере.</Box>
          )}
          {current.type === 'atmos.alarm' && (
            <>
              <div className="NetdmDock__actions">
                <Button icon="tachometer-alt" disabled={disabled || alarmPending}
                  onClick={() => onReadAlarm(current.instance)}>Замер
                </Button>
                <Button icon="bell" selected={watchedAlarm === current.instance}
                  disabled={disabled || watchedAlarm === current.instance}
                  onClick={() => onWatchAlarm(current.instance)}>
                  {watchedAlarm === current.instance ? 'Под наблюдением' : 'Следить'}
                </Button>
              </div>
              {!!current.canControlAlarm && (
                <details className="NetdmDock__disclosure">
                  <summary>Управление тревогой</summary>
                  <div className="NetdmDock__actions">
                    <Button.Confirm icon="exclamation-circle" content="Поднять тревогу"
                      confirmContent="Поднять тревогу панели?"
                      disabled={disabled || machinePending} onClick={() => onSetAlarm(current.instance, true)} />
                    <Button.Confirm icon="bell-slash" content="Снять тревогу"
                      confirmContent="Снять тревогу панели?"
                      disabled={disabled || machinePending} onClick={() => onSetAlarm(current.instance, false)} />
                  </div>
                </details>
              )}
            </>
          )}
          {doorPanel && (
            <DoorPanel key={current.instance} state={doorPanel} disabled={disabled || machinePending}
              onAction={command => onDoorAction(current.instance, command)} />
          )}
          {!hasDedicatedControls && serviceActions}
        </div>
      ) : <Box color="label">Известных сервисов пока нет.</Box>}
      {(node.flags & FLAG_APC) !== 0 && travel.state === 'here' && (
        <div className="NetdmDock__card NetdmBreach">
          <NetdmBreach hack={hack} selected={id} enabled={active && !stale}
            onStart={() => onHack(id)} onAnswer={onHackAnswer} onUse={() => onHackUse(id)} />
        </div>
      )}
      {recent.length > 0 && (
        <details className="NetdmNode__details NetdmDock__disclosure">
          <summary>Активность узла</summary>
          {recent.map(item => (
            <Box key={`${item.seq}-${item.kind}-${item.node}`} className="NetdmDock__event" color="label">
              {item.name ? `${item.name}: ` : ''}{item.text || item.kind}
            </Box>
          ))}
        </details>
      )}
      <details className="NetdmNode__details NetdmDock__disclosure">
        <summary>Диагностика</summary>
        <div className="NetdmDock__mono">
          X {node.x} · Y {node.y}
          {!!current && <div>{current.instance}{current.stale ? ' · устарел' : ''}</div>}
        </div>
        <div className="NetdmDock__actions">
          <Button icon="signal" disabled={!active} onClick={() => onTrace(id)}>Проверить связь</Button>
          {!!onPrepareTerminal && !!current && safeServiceIdentifier(current.type) && (
            <Button icon="terminal" onClick={() => onPrepareTerminal(`api ${current.type}`)}>
              Подготовить запрос API
            </Button>
          )}
        </div>
        {hasDedicatedControls && serviceActions}
      </details>
    </div>
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
            <Button icon="sign-in-alt" disabled={!canMove} onClick={() => onMove(preview.target)}
              tooltip="Подтвердить рассчитанный маршрут (Enter)">
              Перейти · Enter
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
  nodes: NearbyNode[];
  destinations: NearbyDestination[];
  anchor: string | null;
  selected: string | null;
  active: boolean;
  moving: boolean;
  pending: boolean;
  onInspect: (node: string) => void;
  onPreview: (destination: NearbyDestination) => void;
}) => (
  <Section title={props.anchor ? `Соседи узла ${props.anchor}` : 'Соседние узлы'}>
    {props.nodes.length === 0 ? (
      <Box color="label">Известных соседей нет. Можно сканировать сеть.</Box>
    ) : (
      <Stack vertical>
        {props.nodes.map(node => {
          const destination = props.destinations.find(item => item.node === node.node);
          return (
            <Stack.Item key={node.node}>
              <Stack align="center" wrap>
                <Stack.Item grow>
                  <Button
                    fluid
                    icon={node.radio ? 'wifi' : 'network-wired'}
                    selected={props.selected === node.node}
                    tooltip={node.unavailable
                      ? 'Связь не работает, но можно осмотреть известный узел'
                      : 'Выбрать и центрировать на карте; сетевых команд нет'}
                    onClick={() => props.onInspect(node.node)}>
                    Осмотреть узел {node.node}{node.unavailable ? ' · нет связи' : ''}
                  </Button>
                </Stack.Item>
                {!!destination && (
                  <Stack.Item>
                    <Button
                      icon="route"
                      disabled={!props.active || props.moving || props.pending || destination.unavailable}
                      tooltip={destination.unavailable
                        ? 'Переход недоступен'
                        : 'Запросить подтверждённый маршрут у Host, без перемещения'}
                      onClick={() => props.onPreview(destination)}>
                      Маршрут
                    </Button>
                  </Stack.Item>
                )}
              </Stack>
            </Stack.Item>
          );
        })}
      </Stack>
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

const hasReportedState = (value: BooleanLike) => value !== null && value !== undefined;

const MachineCommandPanel = (props: { command: MachineCommand }) => {
  const { instance, enabled, status, operation, reason, source, zoneAlarm, sourceActive,
    kind, doorAction, doorOpen, doorBolted, changed } = props.command;
  const isDoor = kind === 'door';
  const { text, color } = MACHINE_STATUS[status] ?? MACHINE_STATUS.unknown;
  const reasonText = reason && ((isDoor && DOOR_REASON[reason]) || MACHINE_REASON[reason] || reason);
  const actionLabel = isDoor ? (doorAction && DOOR_ACTIONS[doorAction]?.label) || 'Управление шлюзом'
    : enabled ? 'Поднять тревогу' : 'Снять тревогу панели';
  return (
    <Section title={isDoor ? 'Команда шлюза' : 'Команда атмосферной панели'}>
      <Box title={instance}>{actionLabel}</Box>
      <Box aria-live="polite" bold color={color}>{isDoor ? DOOR_STATUS[status] ?? text : text}</Box>
      {isDoor && status === 'applied' && hasReportedState(doorOpen) && hasReportedState(doorBolted) && (
        <Box color="label">
          {describeDoorState(doorOpen, doorBolted)}
          {hasReportedState(changed) && !changed && ' · состояние уже соответствовало команде'}
        </Box>
      )}
      {!isDoor && status === 'applied' && hasReportedState(zoneAlarm) && hasReportedState(sourceActive) && (
        <Box color={zoneAlarm ? 'average' : 'label'}>
          {sourceActive ? 'Тревога панели активна' : 'Тревога панели снята'}
          {zoneAlarm && !sourceActive ? ' · в зоне остались другие тревоги' : ''}
        </Box>
      )}
      {reasonText && <Box color="label">{reasonText}</Box>}
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
  onCommand: (command: string) => void;
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
    if (!props.enabled || text.length === 0) {
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
    ?? 'Enter — выполнить · ↑↓ — история';
  return (
    <div>
      <div className="NetdmTerminalWorkspace__composer">
        <select className="NetdmTerminalWorkspace__commandMenu" aria-label="Быстрые команды"
          disabled={!props.enabled} value="" onChange={event => props.onCommand(event.currentTarget.value)}>
          <option value="" disabled>Команды</option>
          <option value="services">Сервисы</option>
          <option value="links">Связи</option>
          <option value="api">API</option>
          <option value="help">Справка</option>
        </select>
        <input
          className="NetdmTerminalWorkspace__commandInput"
          aria-label="Командная строка сети"
          autoComplete="off"
          spellCheck={false}
          maxLength={1024}
          placeholder="Введите команду"
          value={props.line}
          onChange={event => props.onLine(event.currentTarget.value)}
          onKeyDown={event => {
            if (event.nativeEvent.isComposing) return;
            if (event.key === 'Tab' && !event.shiftKey) {
              const completed = tabComplete(props.line, props.dynamic);
              if (completed !== props.line) {
                event.preventDefault();
                props.onLine(completed);
              }
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
        <button type="button" className="NetdmTerminalWorkspace__execute"
          disabled={!props.enabled || !props.line.trim()} onClick={submit}>
          Выполнить
        </button>
      </div>
      <small className="NetdmTerminalWorkspace__usage">{hint}</small>
    </div>
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
  onRead: (visit: string, received: number) => void; onSend: (node: string, text: string) => void;
  onChannel: () => void }) => {
  const { chat, state, firstUnread, onRead, onSend, onChannel } = props;
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
    <div className="NetdmDock__chat">
      <div className="NetdmDock__chatToolbar">
        <Button icon={chat?.channel ? 'map-marker-alt' : 'satellite-dish'} disabled={!chat} onClick={onChannel}>
          {chat?.channel ? 'К чату узла' : 'Общий канал'}
        </Button>
      </div>
      <div className="NetdmDock__chatViewport">
        <div className="NetdmDock__chatHistory" ref={scrollable} onScroll={handleScroll}>
          {!chat && <Box color="label">{unavailable}</Box>}
          {messages?.length === 0 && <Box color="label">Сообщений пока нет.</Box>}
          {messages?.map(message => (
            <div key={message.id} data-chat-message-id={message.id}>
              {message.id === dividerMessage && (
                <div ref={unreadDivider} className="NetdmDock__divider" role="separator" aria-label="Новые сообщения">
                  Новые сообщения
                </div>
              )}
              <div className="NetdmDock__message" data-own={!!message.own}>
                <strong>{message.own ? 'Вы' : message.sender}</strong>
                <div>{message.text}</div>
              </div>
            </div>
          ))}
        </div>
        {newCount > 0 && (
          <div className="NetdmDock__jump" aria-live="polite">
            <Button icon="arrow-down" aria-label={`К новым сообщениям, непрочитанных ${newCount}`}
              onClick={showNewMessages}>К новым · {newCount > 99 ? '99+' : newCount}
            </Button>
          </div>
        )}
      </div>
      {!!chat && (
        <div className="NetdmDock__compose">
          <div className="NetdmDock__composer">
            <input aria-label="Сообщение в чат узла" autoComplete="off" maxLength={CHAT_LIMIT}
              placeholder={chat.channel ? 'В общий канал' : 'Сообщение на узел'}
              value={draft} onChange={event => setDraft(event.currentTarget.value)}
              onKeyDown={event => {
                if (event.key === 'Enter' && !event.nativeEvent.isComposing) {
                  event.preventDefault();
                  send();
                }
              }} />
            <button type="button" aria-label="Отправить сообщение" disabled={pending || !text} onClick={send}>
              <Icon name="paper-plane" />
            </button>
          </div>
          {!!chat.status && CHAT_STATUS[chat.status] && (
            <Box mt={0.5} color={pending || chat.status === 'sent' ? 'label' : 'average'}>{CHAT_STATUS[chat.status]}</Box>
          )}
        </div>
      )}
    </div>
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

const NetworkLifePanel = ({ persona, bots, operators, immersed, enabled, onPersona, onImmerse, onSummon }: {
  persona: Persona | null;
  bots: LifeBot[];
  operators: LifeOperator[];
  immersed: BooleanLike;
  enabled: BooleanLike;
  onPersona: (name: string, signature: string, status: string, colour: number) => void;
  onImmerse: () => void;
  onSummon: (goal: string) => void;
}) => {
  const [summonLabel, setSummonLabel] = useState('Курьер');
  const [name, setName] = useState(persona?.name ?? '');
  const [signature, setSignature] = useState(persona?.signature ?? '');
  const [status, setStatus] = useState(persona?.status ?? '');
  const [colour, setColour] = useState(persona?.colour ?? 0);
  return (
    <>
      <div className="NetdmDock__card">
        <strong>{persona?.name || 'Сетевая личность'}</strong>
        {!!persona?.role && <Box color="label">{persona.role}</Box>}
        {!!persona?.status && <div>{persona.status}</div>}
        {!!enabled && !immersed && (
          <div className="NetdmDock__actions">
            <Button icon="brain" onClick={onImmerse}>Погрузиться</Button>
          </div>
        )}
      </div>
      <details className="NetdmDock__card NetdmDock__disclosure">
        <summary>Настроить профиль</summary>
        <div className="NetdmDock__profile">
          <label className="NetdmDock__field">
            <span>Позывной</span>
            <input value={name} maxLength={24} onChange={event => setName(event.currentTarget.value)} />
          </label>
          <label className="NetdmDock__field">
            <span>Знак</span>
            <input value={signature} maxLength={4} onChange={event => setSignature(event.currentTarget.value)} />
          </label>
          <label className="NetdmDock__field NetdmDock__wide">
            <span>Статус</span>
            <input value={status} maxLength={32} onChange={event => setStatus(event.currentTarget.value)} />
          </label>
        </div>
        <div className="NetdmDock__swatches" aria-label="Цвет профиля">
          {COLOURS.map((entry, index) => (
            <button key={entry} type="button" aria-label={`Цвет ${index + 1}`} aria-pressed={colour === index}
              style={{ backgroundColor: entry }} onClick={() => setColour(index)} />
          ))}
        </div>
        <div className="NetdmDock__actions">
          <Button icon="save" onClick={() => onPersona(name, signature, status, colour)}>Сохранить</Button>
        </div>
      </details>
      <div className="NetdmDock__card">
        <strong>Агенты и операторы</strong>
        {bots.length === 0 && operators.length === 0 && <Box color="label">Других участников поблизости нет.</Box>}
        {bots.map(bot => (
          <div key={bot.bot} className="NetdmDock__event">
            <strong>{bot.name}</strong> <Box inline color="label">· {GOAL_TEXT[bot.goal] ?? bot.goal}</Box>
          </div>
        ))}
        {operators.map((operator, index) => (
          <div key={`${operator.node}-${index}`} className="NetdmDock__event">
            <strong>{operator.name || 'Оператор'}</strong>
            {!!operator.role && <Box inline color="label"> · {operator.role}</Box>}
            {!!operator.status && <div>{operator.status}</div>}
          </div>
        ))}
      </div>
      {!!enabled && (
        <details className="NetdmDock__card NetdmDock__disclosure">
          <summary>Вызвать агента</summary>
          <div className="NetdmDock__paired">
            <label className="NetdmDock__field">
              <span>Роль агента</span>
              <select value={summonLabel} onChange={event => setSummonLabel(event.currentTarget.value)}>
                {Object.keys(SUMMON_GOALS).map(goal => <option key={goal}>{goal}</option>)}
              </select>
            </label>
            <Button icon="user-plus" onClick={() => onSummon(SUMMON_GOALS[summonLabel] ?? 'courier')}>Вызвать</Button>
          </div>
        </details>
      )}
    </>
  );
};

const NetworkEventHistory = ({ activity, incidents }: { activity: LifeEvent[]; incidents: LifeIncident[] }) => (
  <>
    {incidents.length > 0 && (
      <Section title="Происшествия">
        {incidents.slice(-8).reverse().map((incident, index) => (
          <div key={`${incident.at}-${index}`} className="NetdmDock__event">
            <span className="NetdmDock__mono">
              {`${String(Math.floor(incident.at / 60)).padStart(2, '0')}:${String(incident.at % 60).padStart(2, '0')}`}
            </span>
            {' · '}{incident.text}
          </div>
        ))}
      </Section>
    )}
    {activity.length > 0 && (
      <Section title="Активность сети">
        {activity.slice(-12).reverse().map(event => (
          <div key={event.seq} className="NetdmDock__event">
            <span className="NetdmDock__mono">{LIFE_KIND[event.kind] ?? event.kind}</span>
            {' · '}{event.text}
          </div>
        ))}
      </Section>
    )}
  </>
);

// TODO(netdm-ui): split this stateful screen into feature panels and dedicated hooks.
// eslint-disable-next-line complexity
export const NetdmSpace = () => {
  const { act, data } = useBackend<Data>();
  const view = useMemo(
    () => parseView({ nodes: data.nodes, edges: data.edges, down: data.down }),
    [data.nodes, data.edges, data.down],
  );
  const [selected, setSelected] = useState<string | null>(null);
  const [serviceSelection, setServiceSelection] = useState<{ node: string; instance: string }>();
  const [failure, setFailure] = useState<string | null>(null);
  const [radius, setRadius] = useState(3);
  const [fitRequest, setFitRequest] = useState(0);
  const [focusRequest, setFocusRequest] = useState(0);
  const [focusTarget, setFocusTarget] = useState<string | null>(null);
  const [showMapLegend, setShowMapLegend] = useState(false);
  const [line, setLine] = useState('');
  const [terminalOpened, setTerminalOpened] = useState(false);
  const [source, setSource] = useState<'device' | 'presence'>('device');
  const [devicePreset, setDevicePreset] = useState<{ id: number; line: string }>();
  const [sideTab, setSideTab] = useState<SpaceTab>('node');
  const [chatOpening, setChatOpening] = useState<ChatOpening | null>(null);
  const [readChat, setReadChat] = useState<ChatProgress | null>(null);
  const showChat = sideTab === 'chat';
  const presence = data.presence;
  const life = data.life ?? { bots: [], activity: [], operators: [] };
  const persona = data.persona ?? presence?.persona ?? null;
  const immersed = !!data.immersed;
  const entityRole = !!data.entityRole;
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
  const showTerminal = sideTab === 'terminal';
  const deviceTerminal = data.terminal;
  const useDevice = !!deviceTerminal && source === 'device';
  const terminalAct = useCallback((command: string, params: Record<string, unknown> = {}) => {
    act('terminal', { command, params });
  }, [act]);
  const actRef = useRef(act);
  actRef.current = act;
  useEffect(() => {
    if (active) {
      actRef.current('hack_keys');
    }
  }, [active]);
  const entries = data.actionEntries ?? EMPTY_ACTIONS;
  const [signal, setSignal] = useState<SceneSignal | null>(null);
  const shownSignals = useRef(new Map<string, SceneSignal['outcome']>());
  useEffect(() => {
    const signals = new Map<string, SceneSignal['outcome']>();
    let changed: SceneSignal | null = null;
    for (const entry of entries) {
      const delivery = entry.delivery;
      if (!delivery) continue;
      const node = data.services.find(service => service.instance === delivery.instance)?.node;
      if (!node || !view.nodes.has(node)) continue;
      const id = `${entry.id}:${delivery.operation}`;
      const outcome = delivery.state === 'not_delivered' ? 'rejected' : delivery.state;
      signals.set(id, outcome);
      if (shownSignals.current.get(id) !== outcome) {
        changed = { id, node, outcome };
      }
    }
    if (machineCommand?.operation && machineCommand.status !== 'sending') {
      const node = data.services.find(service => service.instance === machineCommand.instance)?.node;
      if (node && view.nodes.has(node)) {
        const id = `${machineCommand.kind ?? 'alarm'}:${machineCommand.operation}`;
        const outcome = {
          sent: 'queued',
          applied: 'delivered',
          rejected: 'rejected',
          not_delivered: 'rejected',
          no_receipt: machineCommand.kind === 'door' ? 'unknown' : 'applied',
          unknown: 'unknown',
        }[machineCommand.status] as SceneSignal['outcome'];
        signals.set(id, outcome);
        if (shownSignals.current.get(id) !== outcome) {
          changed = { id, node, outcome };
        }
      }
    }
    shownSignals.current = signals;
    if (changed) setSignal(changed);
  }, [entries, data.services, view.nodes, machineCommand]);
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
  const selectTab = (tab: SpaceTab) => {
    if (tab === sideTab) return;
    if (tab === 'terminal') setTerminalOpened(true);
    setSideTab(tab);
    setChatOpening(tab === 'chat'
      ? { previousRead: readChat, snapshot: visit ? { visit, received } : null }
      : null);
  };
  const prepareTerminal = (command: string) => {
    if (active) {
      setSource('presence');
      setLine(command);
    } else if (deviceTerminal) {
      setSource('device');
      setDevicePreset(previous => ({ id: (previous?.id ?? 0) + 1, line: command }));
    }
    selectTab('terminal');
  };
  const inspectMap = (node: string | null) => {
    setSelected(node);
    if (node && !showChat) selectTab('node');
  };
  const requestRoute = useCallback((instance: string) => {
    setSideTab('route');
    act('preview_move', { to: instance });
  }, [act]);
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
  const inspectNeighbors = useMemo(() => knownAdjacentNodes(view, shown), [view, shown]);
  const homeNeighbors = useMemo(() => knownAdjacentNodes(view, data.hostNode), [view, data.hostNode]);
  const targetNode = foundTarget && view.nodes.get(foundTarget.node);
  const canMove = active && !!foundTarget && !!targetNode && !foundTarget.stale && !isOffline(targetNode.flags);
  const reason = presence?.reason ? REASON_TEXT[presence.reason] ?? presence.reason : null;
  // Camera movements never imply a presence move. Only server-authorized move can do that.
  const focusHome = useCallback(() => {
    if (data.hostNode && view.nodes.has(data.hostNode)) {
      setSelected(data.hostNode);
      setFocusTarget(data.hostNode);
      setFocusRequest(request => request + 1);
    }
  }, [data.hostNode, view]);
  const focusKnown = useCallback((id: string) => {
    if (view.nodes.has(id)) {
      setSelected(id);
      setFocusTarget(id);
      setFocusRequest(request => request + 1);
    }
  }, [view]);
  useEffect(() => {
    const keyboard = (event: KeyboardEvent) => {
      if (!inside || event.altKey || event.ctrlKey || event.metaKey || event.repeat) {
        return;
      }
      const target = event.target as HTMLElement | null;
      if (target?.closest('input, textarea, select, button, summary, [role="button"], [contenteditable="true"]')) {
        return;
      }
      // The chat and shell are independent input surfaces; shortcuts work only
      // when the player is navigating the main network canvas.
      if (showChat || showTerminal) {
        return;
      }
      if (event.key.toLowerCase() === 'f') {
        event.preventDefault();
        focusHome();
      } else if (event.key === 'Escape') {
        setSelected(null);
      } else if ((event.key === 'ArrowLeft' || event.key === 'ArrowRight') && homeNeighbors.length > 0) {
        // Camera-only navigation among discovered one-hop neighbors.
        const step = event.key === 'ArrowRight' ? 1 : -1;
        const index = homeNeighbors.findIndex(item => item.node === selected);
        const next = index < 0 ? (step > 0 ? 0 : homeNeighbors.length - 1)
          : (index + step + homeNeighbors.length) % homeNeighbors.length;
        event.preventDefault();
        focusKnown(homeNeighbors[next].node);
      } else if (event.key.toLowerCase() === 'g' && active && !moving && !routePending &&
                 selected && selectedTravel.state === 'ready' && selectedTravel.instance) {
        event.preventDefault();
        requestRoute(selectedTravel.instance);
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
  }, [inside, showChat, showTerminal, focusHome, focusKnown, homeNeighbors, active, moving, routePending, selected,
    selectedTravel, canMove, preview, act, requestRoute]);
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
  const terminal = terminalOpened && (
    <div className="NetdmWorkspace">
      {deviceTerminal && (
        <div className="NetdmWorkspace__pane" hidden={!useDevice}>
          <NetdmTerminalContent data={deviceTerminal} act={terminalAct}
            active={showTerminal && useDevice} preset={devicePreset} />
        </div>
      )}
      <div className="NetdmWorkspace__pane NetdmWorkspace__presence" hidden={useDevice}>
        <Section className="NetdmTerminalWorkspace__journal" scrollable fill>
          {data.log.length === 0 && (
            <Box color="label">{active ? 'Ответов пока нет.' : 'Войдите в сеть, чтобы отправлять команды.'}</Box>
          )}
          {[...data.log].reverse().map((entry, index) => (
            <div className="NetdmDock__event" key={index}>{entry}</div>
          ))}
        </Section>
        <ActionBox
          line={line}
          enabled={active}
          dynamic={{
            instances: data.services.map(service => service.instance),
            nodes: [...view.nodes.keys()],
            types: [...new Set(data.services.map(service => service.type))],
          }}
          onLine={setLine}
          onSend={send}
          onCommand={command => active && act('act', { line: command })} />
      </div>
    </div>
  );

  return (
    <Window width={inside ? 1120 : 860} height={inside ? 720 : 600} title={`Сеть: ${data.title}`}>
      <Window.Content>
        <Stack fill vertical>
          <Stack.Item>
            <header className="NetdmToolbar">
              <div className="NetdmToolbar__status" data-state={inside ? presence?.state : 'offline'} role="status">
                <span className="NetdmToolbar__dot" aria-hidden="true" />
                <div className="NetdmToolbar__statusText">
                  <strong>{inside ? STATE_TEXT[presence.state ?? ''] ?? presence.state : 'Вне сети'}</strong>
                  {inside && (
                    <span>
                      {presence.state === 'moving' ? ` → ${presence.to}` : data.hostNode ? ` · Узел ${data.hostNode}` : ''}
                    </span>
                  )}
                  {!!reason && <small>{reason}</small>}
                </div>
              </div>
              <div className="NetdmToolbar__controls">
                {showTerminal && deviceTerminal && (
                  <select className="NetdmToolbar__origin" aria-label="Откуда выполнять" value={source}
                    onChange={event => setSource(event.currentTarget.value === 'device' ? 'device' : 'presence')}>
                    <option value="device">С устройства</option>
                    <option value="presence">С присутствия</option>
                  </select>
                )}
                {!showTerminal && (
                  <>
                    {view.nodes.size > 0 && (
                      <button type="button" className="NetdmToolbar__scan" disabled={!canScan}
                        onClick={() => { selectTab('node'); act('scan', { radius }); }}>
                        <Icon name="satellite-dish" /> Сканировать
                      </button>
                    )}
                    <details className="NetdmToolbar__settings">
                      <summary aria-label="Настройки карты" title="Настройки карты">
                        <Icon name="sliders-h" />
                      </summary>
                      <div className="NetdmToolbar__settingsPanel">
                        <label>
                          Радиус сканирования
                          <select aria-label="Радиус сканирования" value={radius}
                            onChange={event => setRadius(Number(event.currentTarget.value))}>
                            {[1, 2, 3, 4, 5, 6, 7, 8].map(value => <option key={value} value={value}>{value} хоп.</option>)}
                          </select>
                        </label>
                        {data.levels.length > 1 && (
                          <label>
                            Уровень карты
                            <select aria-label="Уровень карты" value={data.z}
                              onChange={event => {
                                setSelected(null);
                                selectTab('node');
                                act('level', { z: Number(event.currentTarget.value) });
                              }}>
                              {data.levels.map(level => <option key={level} value={level}>Z{level}</option>)}
                            </select>
                          </label>
                        )}
                        {inside && !!data.hostNode && view.nodes.has(data.hostNode) && (
                          <button type="button" title="Центрировать на себе (F)"
                            onClick={() => { focusHome(); selectTab('node'); }}>
                            <Icon name="crosshairs" /> Я здесь
                          </button>
                        )}
                        {!failure && view.nodes.size > 0 && (
                          <button type="button" onClick={() => { selectTab('node'); setFitRequest(current => current + 1); }}>
                            <Icon name="expand" /> Вся карта
                          </button>
                        )}
                      </div>
                    </details>
                  </>
                )}
                <div className="NetdmToolbar__group">
                  {immersed && (
                    <Button icon="power-off" color="average" tooltip="Вернуться в тело у точки доступа"
                      onClick={() => act('surface')}>Выйти из погружения
                    </Button>
                  )}
                  {!!presence?.threat && (
                    <Button icon="user-slash" color="bad" tooltip={`На узле: ${presence.threat}`}
                      onClick={() => act('banish')}>Выгнать вторженца
                    </Button>
                  )}
                  {canResume && <Button icon="play" onClick={() => act('enter')}>Продолжить</Button>}
                  {!inside && <Button icon="sign-in-alt" onClick={() => act('enter')}>Войти</Button>}
                  {entityRole ? (
                    <Button.Confirm icon="ghost" content="Покинуть роль" confirmContent="Вернуться к призраку?"
                      onClick={() => act('leave_role')} />
                  ) : inside && (
                    <Button.Confirm icon="sign-out-alt" content="Выйти" confirmContent="Завершить присутствие?"
                      onClick={() => act('leave')} />
                  )}
                </div>
              </div>
            </header>
          </Stack.Item>
          <Stack.Item grow minHeight={0}>
            <Stack fill className="NetdmUnifiedGrid" data-active-tab={sideTab}>
              <Stack.Item grow minWidth={0} position="relative" className="NetdmUnifiedGrid__map"
                aria-hidden={showTerminal}>
                {view.nodes.size === 0 ? (
                  <div className="NetdmUnifiedGrid__discovery">
                    <Icon name="satellite-dish" />
                    <h2>Обнаружение узлов</h2>
                    <p>
                      {canScan ? 'Просканируйте окрестность, чтобы увидеть устройства и связи.'
                        : 'Сканирование доступно при активном присутствии.'}
                    </p>
                    <Button icon="search" disabled={!canScan} onClick={() => act('scan', { radius })}>
                      Обнаружить узлы
                    </Button>
                  </div>
                ) : failure ? (
                  <FallbackList
                    view={view}
                    reason={failure}
                    otherPresences={otherPresences}
                    activity={activity}
                    agents={agents}
                    operators={operators}
                    onSelect={inspectMap}
                    onRetry={() => setFailure(null)} />
                ) : (
                  <div style={{ position: 'relative', width: '100%', height: '100%' }}>
                  <TopologyCanvas
                    playerMap
                    deviceServices={data.services}
                    view={view}
                    levelKey={String(data.z)}
                    selected={selected}
                    presenceNode={inside && presence?.state !== 'moving' ? data.hostNode : null}
                    otherPresences={otherPresences}
                    activity={activity}
                    agents={agents}
                    operators={operators}
                    route={route}
                    signal={signal}
                    filters={FILTERS}
                    fitRequest={fitRequest}
                    focusRequest={focusRequest}
                    focusTarget={focusTarget ?? data.hostNode}
                    onSelect={inspectMap}
                    onFailure={setFailure}
                    onReport={() => undefined} />
                    <MapChrome
                      playerMap
                      deviceServices={data.services}
                      level={data.z}
                      nodeCount={view.nodes.size}
                      linkCount={view.links.size}
                      selected={shown ? view.nodes.get(shown) : undefined}
                      view={view}
                      showLegend={showMapLegend}
                      onToggleLegend={() => setShowMapLegend(value => !value)} />
                  </div>
                )}
              </Stack.Item>
              <Stack.Item minHeight={0} minWidth={0} shrink={0} basis="clamp(248px, 36vw, 376px)">
                <NetdmSpaceDock tab={sideTab} onTab={selectTab} unread={unread}
                  routeActive={moving || !!preview}
                  activityActive={!!watch}
                  terminal={terminal}
                  title={sideTab === 'node' && shown ? `Узел ${shown}`
                    : sideTab === 'operator' && entityRole ? 'Сущность'
                    : sideTab === 'chat' && chat ? (chat.channel ? 'Общий канал' : `Чат узла ${chat.node}`) : undefined}>
                  {sideTab === 'node' && (
                    <NodePanel
                      key={shown ?? 'unknown'}
                      view={view}
                      id={shown}
                      services={data.services}
                      entries={entries}
                      activity={life.activity}
                      travel={selectedTravel}
                      otherPresences={shown ? otherPresences?.[shown] ?? 0 : 0}
                      active={active}
                      alarmPending={!!data.alarmPending}
                      machinePending={machinePending}
                      routePending={routePending}
                      watchedAlarm={watch?.instance ?? null}
                      selectedService={serviceSelection?.node === shown ? serviceSelection.instance : undefined}
                      onSelectService={instance => shown && setServiceSelection({ node: shown, instance })}
                      hack={data.hack}
                      onHack={node => act('hack_start', { node })}
                      onHackAnswer={code => act('hack_answer', { code })}
                      onHackUse={node => act('hack_use', { node })}
                      onSelectCamera={instance => act('select_camera', { instance })}
                      onDoorAction={(instance, command) => act('device_action', { instance, command })}
                      onPreview={requestRoute}
                      onReadAlarm={instance => act('read_alarm', { instance })}
                      onWatchAlarm={instance => act('watch_alarm', { instance })}
                      onSetAlarm={(instance, enabled) => act('machine_alert', { instance, enabled: enabled ? 1 : 0 })}
                      onTrace={trace}
                      onPrepareTerminal={active || deviceTerminal ? prepareTerminal : undefined}
                      onCommand={command => {
                        if (active && command.length <= 1024) {
                          act('act', { line: command });
                        }
                      }} />
                  )}
                  {sideTab === 'route' && (
                    <>
                      <RoutePanel
                        preview={preview}
                        presence={presence}
                        canMove={canMove}
                        onMove={target => act('move', { to: target })}
                        onRetry={requestRoute}
                        onClear={() => act('clear_route_preview')}
                        onAbort={() => act('abort_move')} />
                      {inside ? (
                        <NearbyMovementPanel
                          nodes={inspectNeighbors}
                          destinations={nearby}
                          anchor={shown}
                          selected={selected}
                          active={active}
                          moving={moving}
                          pending={routePending}
                          onInspect={focusKnown}
                          onPreview={destination => {
                            focusKnown(destination.node);
                            requestRoute(destination.instance);
                          }} />
                      ) : <Box className="NetdmDock__empty">Войдите в сеть, чтобы прокладывать маршруты.</Box>}
                    </>
                  )}
                  {sideTab === 'operator' && (
                    <>
                      {immersed && (
                        <NoticeBox warning>
                          Тело оставлено у точки доступа.
                          {!!data.immersedSeconds && ` · В сети ${Math.floor((data.immersedSeconds ?? 0) / 60)} мин ${(data.immersedSeconds ?? 0) % 60} с`}
                          {!!data.immersionReason && ` · ${data.immersionReason}`}
                        </NoticeBox>
                      )}
                      <NetworkLifePanel
                        persona={persona}
                        bots={life.bots}
                        operators={life.operators ?? []}
                        immersed={data.immersed}
                        enabled={data.immersionEnabled}
                        onPersona={(name, signature, status, colour) => act('persona', { name, signature, status, colour })}
                        onImmerse={() => act('immerse')}
                        onSummon={goal => act('call_agent', { goal })} />
                      <details className="NetdmDock__card NetdmDock__disclosure">
                        <summary>Приватность и ключи</summary>
                        <div className="NetdmDock__actions">
                          <Button icon={data.hack?.masked ? 'user-secret' : 'user'}
                            selected={!!data.hack?.masked} disabled={!active} onClick={() => act('hack_mask')}>
                            {data.hack?.masked ? 'Личность скрыта' : 'Скрыть личность'}
                          </Button>
                          <Button icon="sync" disabled={!active} onClick={() => act('hack_keys')}>Обновить ключи</Button>
                        </div>
                      </details>
                    </>
                  )}
                  {sideTab === 'activity' && (
                    <>
                      {watch && (
                        <AlarmWatchPanel
                          watch={watch}
                          onSelect={() => {
                            selectTab('node');
                            if (watch.z !== null && watch.z !== data.z) {
                              setSelected(watch.node);
                              act('level', { z: watch.z });
                            } else {
                              focusKnown(watch.node);
                            }
                          }}
                          onStop={() => act('stop_alarm_watch')} />
                      )}
                      <Section title="Журнал">
                        <NetdmDeliveryActivity entries={entries} onSelect={instance => {
                          const node = data.services.find(service => service.instance === instance)?.node;
                          if (node && view.nodes.has(node)) {
                            focusKnown(node);
                            selectTab('node');
                          }
                        }} />
                        {machineCommand && <MachineCommandPanel command={machineCommand} />}
                        {data.log.length === 0 && !entries.some(entry => entry.delivery) && !machineCommand && (
                          <Box color="label">Событий пока нет.</Box>
                        )}
                        {[...data.log].reverse().map((entry, index) => (
                          <div className="NetdmDock__event" key={index}>{entry}</div>
                        ))}
                      </Section>
                      {deviceTerminal && (!!deviceTerminal.events?.length || !!deviceTerminal.watches?.length) && (
                        <NetdmTerminalEvents data={deviceTerminal} onCommand={line => terminalAct('run', { line })} />
                      )}
                      <NetworkEventHistory activity={life.activity} incidents={data.incidents ?? []} />
                    </>
                  )}
                  {showChat && (
                    <NodeChatPanel
                      key={chat?.visit ?? 'connecting'}
                      chat={chat}
                      state={presence?.state}
                      firstUnread={firstUnread}
                      onRead={markChatRead}
                      onSend={(node, text) => act('send_chat', { node, text })}
                      onChannel={() => act('chat_channel')} />
                  )}
                </NetdmSpaceDock>
              </Stack.Item>
            </Stack>
          </Stack.Item>
        </Stack>
      </Window.Content>
    </Window>
  );
};
