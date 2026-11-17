import { BooleanLike } from 'common/react';
import { useState } from 'react';

import { Box, Button, Icon } from '../components';
import { NetdmDevicePanel } from './NetdmDevicePanel';
import { DeviceEvent } from './NetdmDeviceState';

/**
 * The welcoming view is strictly a projection of already acknowledged shell data.
 * It never enumerates devices, subscribes, or executes network commands on mount.
 * Every action goes through the same DM shell and ServiceRuntime as advanced tools.
 */
export type HomeEntry = {
  id: number;
  line: string;
  pending: BooleanLike;
  status: string | null;
  error: string | null;
  records: { name: string; value: string }[][];
};

type ServiceInfo = {
  instance: string;
  type: string;
  hops: string | null;
};

export const visibleServices = (entries: HomeEntry[]): {
  query: HomeEntry | null;
  source: HomeEntry | null;
  services: ServiceInfo[];
} => {
  const queries = [...entries].reverse().filter(entry => /^services(?:\s|$)/.test(entry.line));
  const query = queries[0] ?? null;
  // Keep the last acknowledged directory snapshot while a newer search is in flight.
  // The UI marks it as earlier data; it must never be mistaken for a fresh discovery.
  const source = queries.find(entry => !entry.pending && entry.status === 'ok') ?? null;
  if (!source) {
    return { query, source: null, services: [] };
  }
  const seen = new Set<string>();
  const services = source.records.flatMap(fields => {
    const value = (name: string) => fields.find(field => field.name === name)?.value;
    const instance = value('instance');
    const type = value('type');
    if (!instance || !type || !/^[a-zA-Z0-9._-]{1,64}$/.test(instance) || seen.has(instance)) {
      return [];
    }
    seen.add(instance);
    return [{ instance, type, hops: value('hops') ?? null }];
  });
  return { query, source, services };
};

export const networkIssue = (status: string | null, error?: string | null): string => {
  const reason = `${status ?? ''} ${error ?? ''}`.toLowerCase();
  if (/no_answer|timeout|timed_out|no_receipt/.test(reason)) {
    return 'Устройство пока не ответило. Проверьте соединение или повторите запрос.';
  }
  if (/unavailable|no_route|unreachable|not_delivered|route_failed/.test(reason)) {
    return 'Нет доступного сетевого пути к устройству.';
  }
  if (/denied|refused|forbidden|not_allowed|unauthorized/.test(reason)) {
    return 'Доступ к действию ограничен.';
  }
  if (/no_power|unpowered|offline/.test(reason)) {
    return 'Устройство недоступно или обесточено.';
  }
  if (/unknown_service|not_found/.test(reason)) {
    return 'Этот сервис больше не обнаруживается в сети.';
  }
  return 'Сеть не смогла завершить запрос. Подробности доступны в журнале.';
};

const categoryName = (type: string) => {
  if (type === 'atmos.alarm') return 'Атмосферная тревога';
  if (type === 'atmos.telemetry') return 'Датчик атмосферы';
  if (type.startsWith('research.')) return 'Научная система';
  if (type.startsWith('machine.')) return 'Устройство';
  if (type === 'network.shell') return 'Сетевая консоль';
  if (type.startsWith('messenger.')) return 'Связь';
  return type;
};

const serviceIcon = (type: string) => {
  if (type.startsWith('atmos.')) return 'wind';
  if (type.startsWith('research.')) return 'flask';
  if (type.startsWith('machine.')) return 'microchip';
  if (type === 'network.shell') return 'terminal';
  return 'network-wired';
};

const Activity = ({
  entry, onOpenLog,
}: {
  entry?: HomeEntry;
  onOpenLog: () => void;
}) => {
  const value = (field: string) => entry?.records
    .flatMap(record => record).find(item => item.name === field)?.value;
  const operation = entry && /^invoke atmos\.alarm\.[^\s]+ read\b/.test(entry.line)
    ? value('operation') : null;
  const readTicket = operation && /^[1-9][0-9]{0,17}$/.test(operation) ? operation : null;
  const text = !entry ? 'Пока нет запросов.'
    : entry.pending ? 'Запрос в пути. Ожидается ответ по сети.'
      : readTicket ? 'Запрос принят в сеть. Выберите устройство, чтобы проверить результат.'
        : entry.status === 'ok' ? 'Ответ от сетевого сервиса получен.'
          : entry.status === 'valid' ? 'Исходник проверен. Команды не выполнялись.'
            : entry.status === 'started' || entry.status === 'running' ? 'Программа принята сетевым сервисом.'
              : networkIssue(entry.status, entry.error);
  return (
    <div className="NetdmHome__activity">
      <div className="NetdmHome__sectionLabel">ПОСЛЕДНЕЕ ДЕЙСТВИЕ</div>
      <div className="NetdmHome__activityText">{text}</div>
      {!!entry && (
        <>
          <div className="NetdmHome__activityCommand">{entry.line}</div>
          {!!entry.error && !entry.pending && entry.status !== 'ok' && (
            <Box color="label" mt={0.5}>Код: {entry.status}. Подробности — в журнале.</Box>
          )}
          <Button icon="history" content="Открыть историю" onClick={onOpenLog} />
        </>
      )}
    </div>
  );
};

type Props = {
  title: string;
  connected: boolean;
  entries: HomeEntry[];
  events: number;
  watches: number;
  watchKeys: string[];
  eventFeed: DeviceEvent[];
  onDiscover: () => void;
  onAlarms: () => void;
  onMap: () => void;
  onEvents: () => void;
  onAdvanced: () => void;
  onInspect: (line: string) => void;
  onCommand: (line: string) => void;
};

export const NetdmHome = (props: Props) => {
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const { query, source, services } = visibleServices(props.entries);
  const latest = props.entries[props.entries.length - 1];
  const limited = services.slice(0, 6);
  const selected = limited.find(service => service.instance === selectedId) ?? null;
  const subscribed = selected !== null && props.watchKeys.includes(selected.instance);
  const changingSubscription = selected !== null && props.entries.some(entry =>
    !!entry.pending && (entry.line === `watch ${selected.instance} -key ${selected.instance}` ||
      entry.line === `unwatch ${selected.instance}`));
  const pending = !!query?.pending;
  const previousResults = !!source && !!query && source.id !== query.id;

  return (
    <div className="NetdmHome">
      <div className="NetdmHome__hero">
        <div className="NetdmHome__heroMain">
          <div className="NetdmHome__eyebrow">NTNET / СЕТЕВОЙ ДОСТУП</div>
          <div className="NetdmHome__title">Сеть станции</div>
          <div className="NetdmHome__subtitle">{props.title} · Устройства, показания и события в одной панели</div>
        </div>
        <div className={'NetdmHome__status ' + (props.connected ? 'NetdmHome__status--ready' : 'NetdmHome__status--waiting')}>
          <span className="NetdmHome__statusDot" />
          {props.connected ? 'Подключено' : 'Связь не подтверждена'}
        </div>
      </div>

      <div className="NetdmHome__caption">ЧТО ХОТИТЕ СДЕЛАТЬ?</div>
      <div className="NetdmHome__actions">
        <button type="button" className="NetdmHome__action" onClick={props.onDiscover}>
          <span className="NetdmHome__actionIcon"><Icon name="search" /></span>
          <span className="NetdmHome__actionTitle">Найти устройства</span>
          <span className="NetdmHome__actionDescription">Посмотреть доступные сетевые сервисы</span>
          <span className="NetdmHome__actionArrow"><Icon name="arrow-right" /></span>
        </button>
        <button type="button" className="NetdmHome__action" onClick={props.onAlarms}>
          <span className="NetdmHome__actionIcon"><Icon name="wind" /></span>
          <span className="NetdmHome__actionTitle">Тревоги атмосферы</span>
          <span className="NetdmHome__actionDescription">Найти панели и проверить их показания</span>
          <span className="NetdmHome__actionArrow"><Icon name="arrow-right" /></span>
        </button>
        <button type="button" className="NetdmHome__action" onClick={props.onMap}>
          <span className="NetdmHome__actionIcon"><Icon name="project-diagram" /></span>
          <span className="NetdmHome__actionTitle">Карта сети</span>
          <span className="NetdmHome__actionDescription">Увидеть узлы и связи станции</span>
          <span className="NetdmHome__actionArrow"><Icon name="arrow-right" /></span>
        </button>
      </div>

      <div className="NetdmHome__columns">
        <section className="NetdmHome__panel">
          <div className="NetdmHome__panelHeading">
            <div>
              <div className="NetdmHome__sectionLabel">ОБНАРУЖЕНИЕ</div>
              <div className="NetdmHome__panelTitle">Устройства в сети</div>
            </div>
            {services.length > 0 && <span className="NetdmHome__count">{services.length}</span>}
          </div>
          {previousResults && (
            <div className="NetdmHome__previous" role="status">
              <Icon name={pending ? 'sync' : 'exclamation-circle'} />
              <span>
                {pending ? 'Идёт обновление. Ниже результаты прошлого поиска.'
                  : 'Новый поиск не завершился. Ниже предыдущие результаты — доступность могла измениться.'}
              </span>
              {!pending && query && <Button icon="redo" content="Повторить"
                onClick={() => props.onCommand(query.line)} />}
            </div>
          )}
          {!query && (
            <div className="NetdmHome__empty">
              <Icon name="satellite-dish" size={2} />
              <div className="NetdmHome__emptyTitle">Пока ничего не искали</div>
              <div>Нажмите «Найти устройства», чтобы увидеть доступные сервисы.</div>
            </div>
          )}
          {pending && !previousResults && (
            <div className="NetdmHome__empty">
              <Icon name="circle-notch" spin size={2} />
              <div className="NetdmHome__emptyTitle">Ищем через сеть…</div>
              <div>Результат появится после ответа Host.</div>
            </div>
          )}
          {query && !pending && query.status !== 'ok' && !previousResults && (
            <div className="NetdmHome__empty">
              <Icon name="unplug" size={2} />
              <div className="NetdmHome__emptyTitle">Не удалось получить список</div>
              <div>{query.error || 'Проверьте связь и повторите поиск.'}</div>
            </div>
          )}
          {query && !pending && query.status === 'ok' && services.length === 0 && (
            <div className="NetdmHome__empty">
              <Icon name="info-circle" size={2} />
              <div className="NetdmHome__emptyTitle">Сервисы не найдены</div>
              <div>В выбранной категории пока нет доступных устройств.</div>
            </div>
          )}
          {limited.map(service => (
            <button type="button" className={'NetdmHome__service NetdmHome__serviceSelect' +
              (selected?.instance === service.instance ? ' NetdmHome__service--selected' : '')}
              key={service.instance}
              aria-label={`Открыть устройство ${service.instance}`}
              aria-expanded={selected?.instance === service.instance}
              onClick={() => setSelectedId(current => current === service.instance ? null : service.instance)}>
              <span className="NetdmHome__serviceIcon"><Icon name={serviceIcon(service.type)} /></span>
              <span className="NetdmHome__serviceMain">
                <span className="NetdmHome__serviceTitle">{categoryName(service.type)}</span>
                <span className="NetdmHome__serviceId">{service.instance}</span>
                {service.hops !== null && <span className="NetdmHome__serviceMeta">Переходов: {service.hops}</span>}
              </span>
              <span className="NetdmHome__serviceOpen">
                {props.watchKeys.includes(service.instance) && <Icon name="bell" />}
                <Icon name={selected?.instance === service.instance ? 'chevron-up' : 'chevron-right'} />
              </span>
            </button>
          ))}
          {selected && (
            <NetdmDevicePanel
              key={selected.instance}
              instance={selected.instance}
              type={selected.type}
              hops={selected.hops}
              entries={props.entries}
              events={props.eventFeed}
              subscribed={subscribed}
              changingSubscription={changingSubscription}
              onCommand={props.onCommand}
              onInspect={props.onInspect}
            />
          )}
          {services.length > limited.length && (
            <div className="NetdmHome__more">
              <Button icon="list" content="Весь список и подробности" onClick={props.onAdvanced} />
            </div>
          )}
        </section>
        <aside className="NetdmHome__sidebar">
          <div className="NetdmHome__activity">
            <div className="NetdmHome__sectionLabel">НАБЛЮДЕНИЕ</div>
            <div className="NetdmHome__watchCount">{props.events}</div>
            <div className="NetdmHome__activityText">
              {props.events === 1 ? 'Полученное событие' : 'Полученных событий'}
            </div>
            <div className="NetdmHome__minor">{props.watches} активных наблюдений</div>
            <Button icon="bell" content="Открыть события" onClick={props.onEvents} />
          </div>
          <Activity entry={latest} onOpenLog={props.onAdvanced} />
          <div className="NetdmHome__deep">
            <div className="NetdmHome__deepTitle">Хотите глубже?</div>
            <div className="NetdmHome__minor">Маршруты, API, скрипты и диагностика доступны в расширенном режиме.</div>
            <Button icon="terminal" content="Открыть инструменты" onClick={props.onAdvanced} />
          </div>
        </aside>
      </div>
    </div>
  );
};
