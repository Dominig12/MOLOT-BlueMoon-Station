import { useState } from 'react';

import { Box, Button, Icon } from '../components';
import {
  alarmStateLabel,
  AtmosReading,
  DeviceEntry,
  DeviceEvent,
  deviceLastEvent,
  deviceReadState,
} from './NetdmDeviceState';

type Props = {
  instance: string;
  type: string;
  hops: string | null;
  entries: DeviceEntry[];
  events: DeviceEvent[];
  subscribed: boolean;
  changingSubscription: boolean;
  onCommand: (command: string) => void;
  onInspect: (command: string) => void;
};

const Measurement = ({
  title, reading, note,
}: { title: string; reading: AtmosReading; note: string }) => (
  <div className="NetdmHome__measurement">
    <div className="NetdmHome__measurementHeader">
      <div className="NetdmHome__sectionLabel">{title}</div>
      <div className={'NetdmHome__measurementState' +
        (reading.alarm === true || reading.danger === 2 ? ' NetdmHome__measurementState--alert' : '')}>
        {alarmStateLabel(reading)}
      </div>
    </div>
    <div className="NetdmHome__measurementValues">
      <div>
        <span className="NetdmHome__measurementNumber">{reading.pressureKPa}</span>
        <span className="NetdmHome__measurementUnit"> кПа</span>
        <div className="NetdmHome__measurementLabel">Давление</div>
      </div>
      <div>
        <span className="NetdmHome__measurementNumber">{reading.temperatureK}</span>
        <span className="NetdmHome__measurementUnit"> K</span>
        <div className="NetdmHome__measurementLabel">Температура</div>
      </div>
    </div>
    <div className="NetdmHome__measurementNote">{note}</div>
  </div>
);

/** Ordinary controls first; routing, raw schema and shell only after opting in. */
export const NetdmDevicePanel = ({
  instance, type, hops, entries, events, subscribed,
  changingSubscription, onCommand, onInspect,
}: Props) => {
  const [details, setDetails] = useState(false);
  const read = deviceReadState(entries, instance);
  const event = deviceLastEvent(events, instance);
  const isAlarm = type === 'atmos.alarm';
  const observable = type === 'atmos.alarm' || type === 'atmos.telemetry';
  const reading = isAlarm && read.phase === 'ready' ? read.reading : null;
  const inFlight = read.phase === 'sending' || read.phase === 'checking';
  const canRequest = isAlarm && !inFlight && read.phase !== 'queued';
  const canCheck = read.operation && ['queued', 'waiting'].includes(read.phase);

  return (
    <div className="NetdmHome__details">
      <div className="NetdmHome__sectionLabel">ВЫБРАННОЕ УСТРОЙСТВО</div>
      <div className="NetdmHome__detailsTitle">{instance}</div>
      <div className="NetdmHome__minor">
        {hops === null ? 'Расстояние не определено' : `Сетевых переходов: ${hops}`}
        {subscribed && ' · Наблюдение включено'}
      </div>
      {isAlarm && (
        <>
          {reading ? (
            <Measurement title="ОТВЕТ НА ЗАПРОС" reading={reading}
              note="Показания получены через сеть. Для свежего измерения запросите их ещё раз." />
          ) : (
            <div className="NetdmHome__requestState" role="status">
              <Icon name={inFlight ? 'clock' : 'info-circle'} />
              <span>
                {read.phase === 'sending' && 'Запрашиваем показания по сети…'}
                {read.phase === 'queued' && 'Запрос отправлен. Ответ ещё не получен.'}
                {read.phase === 'checking' && 'Проверяем доставку ответа…'}
                {read.phase === 'waiting' && 'Доставленного результата пока нет.'}
                {read.phase === 'failed' && 'Не удалось запросить показания. Попробуйте ещё раз.'}
                {read.phase === 'idle' && 'Показания ещё не запрашивались.'}
              </span>
            </div>
          )}
          <div className="NetdmHome__detailsActions">
            <Button icon="tachometer-alt" content="Запросить показания"
              tooltip="Новый запрос к устройству через действующий сетевой маршрут"
              disabled={!canRequest}
              onClick={() => onCommand(`invoke ${instance} read reason=inspect`)} />
            {!!canCheck && (
              <Button icon="poll" content={read.phase === 'waiting' ? 'Проверить ещё раз' : 'Получить ответ'}
                onClick={() => onCommand(`result ${read.operation}`)} />
            )}
          </div>
        </>
      )}
      {!!event && (
        <Measurement
          title={event.schema === 'atmos.alarm_state' ? 'ПОСЛЕДНЕЕ СОБЫТИЕ ТРЕВОГИ' : 'ПОСЛЕДНЕЕ СОБЫТИЕ ДАТЧИКА'}
          reading={event.reading}
          note={`Событие № ${event.delivery} доставлено по сети. Это история наблюдения, не гарантия текущего состояния.`}
        />
      )}
      {!isAlarm && !event && (
        <div className="NetdmHome__requestState">
          <Icon name="info-circle" />
          <span>Новых данных об устройстве нет. Доступные действия зависят от типа сервиса.</span>
        </div>
      )}
      <div className="NetdmHome__detailsActions">
        {observable && (
          <Button icon={subscribed ? 'bell-slash' : 'bell'}
            content={subscribed ? 'Не следить' : 'Следить за событиями'}
            disabled={changingSubscription}
            tooltip="Подписка не выполняет действий с оборудованием — только доставляет события"
            onClick={() => onCommand(subscribed ? `unwatch ${instance}` : `watch ${instance} -key ${instance}`)} />
        )}
        <Button icon={details ? 'chevron-up' : 'chevron-down'}
          content={details ? 'Скрыть техническое' : 'Технические возможности'}
          onClick={() => setDetails(!details)} />
      </div>
      {details && (
        <div className="NetdmHome__technical">
          <Box color="label" mb={1}>
            Путь, описание API и диагностика откроются в расширенном режиме.
            Эти действия не управляют физическим оборудованием.
          </Box>
          <Button icon="route" content="Посмотреть маршрут"
            onClick={() => onInspect(`route ${instance}`)} />
          <Button icon="code" content="Описание API"
            onClick={() => onInspect(`api ${type}`)} />
        </div>
      )}
      <div className="NetdmHome__detailFoot">
        Изменения состояния подтверждаются реальными сетевыми ответами. Отправка команды не равна её исполнению.
      </div>
    </div>
  );
};
