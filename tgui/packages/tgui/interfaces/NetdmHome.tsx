import { BooleanLike } from 'common/react';

import { Box, Button, Icon } from '../components';

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
  services: ServiceInfo[];
} => {
  const query = [...entries].reverse().find(entry => /^services(?:\s|$)/.test(entry.line)) ?? null;
  if (!query || !!query.pending || query.status !== 'ok') {
    return { query, services: [] };
  }
  const seen = new Set<string>();
  const services = query.records.flatMap(fields => {
    const value = (name: string) => fields.find(field => field.name === name)?.value;
    const instance = value('instance');
    const type = value('type');
    if (!instance || !type || !/^[a-zA-Z0-9._-]{1,64}$/.test(instance) || seen.has(instance)) {
      return [];
    }
    seen.add(instance);
    return [{ instance, type, hops: value('hops') ?? null }];
  });
  return { query, services };
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
  entry, onOpenLog, onCommand,
}: {
  entry?: HomeEntry;
  onOpenLog: () => void;
  onCommand: (command: string) => void;
}) => {
  const value = (field: string) => entry?.records
    .flatMap(record => record).find(item => item.name === field)?.value;
  const operation = entry && /^invoke atmos\.alarm\.[^\s]+ read\b/.test(entry.line)
    ? value('operation') : null;
  const readTicket = operation && /^[1-9][0-9]{0,17}$/.test(operation) ? operation : null;
  const pressure = entry && /^result [1-9][0-9]*$/.test(entry.line) ? value('pressureKPa') : null;
  const temperature = pressure !== null && pressure !== undefined ? value('temperatureK') : null;
  const hasReading = entry?.status === 'ok' && pressure !== null && pressure !== undefined &&
    temperature !== null && temperature !== undefined;
  const text = !entry ? 'Пока нет запросов.'
    : entry.pending ? 'Запрос в пути. Ожидается ответ по сети.'
      : readTicket ? 'Запрос принят в сеть. Измерение ещё нужно получить после доставки.'
        : entry.status === 'ok' ? 'Ответ от сетевого сервиса получен.'
          : entry.status === 'valid' ? 'Исходник проверен. Команды не выполнялись.'
            : entry.status === 'started' || entry.status === 'running' ? 'Программа принята сетевым сервисом.'
              : 'Операция завершилась отказом или без ответа.';
  return (
    <div className="NetdmHome__activity">
      <div className="NetdmHome__sectionLabel">ПОСЛЕДНЕЕ ДЕЙСТВИЕ</div>
      <div className="NetdmHome__activityText">{text}</div>
      {hasReading && (
        <div className="NetdmHome__reading">
          <div><strong>{pressure}</strong> кПа</div>
          <div>{temperature} K · {value('alarm') === 'true' ? 'Есть тревога' : 'Тревоги нет'}</div>
        </div>
      )}
      {!!readTicket && !entry?.pending && (
        <Button icon="poll" content="Получить ответ"
          tooltip="Результат доступен только после сетевой доставки"
          onClick={() => onCommand(`result ${readTicket}`)} />
      )}
      {!!entry && (
        <>
          <div className="NetdmHome__activityCommand">{entry.line}</div>
          {!!entry.error && !entry.pending && <Box color="bad" mt={0.5}>{entry.error}</Box>}
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
  onDiscover: () => void;
  onAlarms: () => void;
  onMap: () => void;
  onEvents: () => void;
  onAdvanced: () => void;
  onCommand: (line: string) => void;
};

export const NetdmHome = (props: Props) => {
  const { query, services } = visibleServices(props.entries);
  const latest = props.entries[props.entries.length - 1];
  const limited = services.slice(0, 6);
  const pending = !!query?.pending;

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
          {!query && (
            <div className="NetdmHome__empty">
              <Icon name="satellite-dish" size={2} />
              <div className="NetdmHome__emptyTitle">Пока ничего не искали</div>
              <div>Нажмите «Найти устройства», чтобы увидеть доступные сервисы.</div>
            </div>
          )}
          {pending && (
            <div className="NetdmHome__empty">
              <Icon name="circle-notch" spin size={2} />
              <div className="NetdmHome__emptyTitle">Ищем через сеть…</div>
              <div>Результат появится после ответа Host.</div>
            </div>
          )}
          {query && !pending && query.status !== 'ok' && (
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
            <div className="NetdmHome__service" key={service.instance}>
              <div className="NetdmHome__serviceIcon"><Icon name={serviceIcon(service.type)} /></div>
              <div className="NetdmHome__serviceMain">
                <div className="NetdmHome__serviceTitle">{categoryName(service.type)}</div>
                <div className="NetdmHome__serviceId">{service.instance}</div>
                {service.hops !== null && <div className="NetdmHome__serviceMeta">Переходов: {service.hops}</div>}
              </div>
              <div className="NetdmHome__serviceActions">
                {service.type === 'atmos.alarm' && (
                  <Button icon="tachometer-alt" content="Показания" tooltip="Запросить измерение через сеть"
                    onClick={() => props.onCommand(`invoke ${service.instance} read reason=inspect`)} />
                )}
                {(service.type === 'atmos.alarm' || service.type === 'atmos.telemetry') && (
                  <Button icon="bell" tooltip="Подписаться на новые события этого устройства"
                    content="Следить" onClick={() => props.onCommand(`watch ${service.instance} -key ${service.instance}`)} />
                )}
              </div>
            </div>
          ))}
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
          <Activity entry={latest} onOpenLog={props.onAdvanced} onCommand={props.onCommand} />
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
