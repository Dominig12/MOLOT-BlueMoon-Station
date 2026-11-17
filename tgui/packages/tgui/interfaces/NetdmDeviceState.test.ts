import {
  alarmStateLabel,
  atmosReading,
  deviceLastEvent,
  deviceReadState,
} from './NetdmDeviceState';

const row = (values: Record<string, string>) =>
  Object.entries(values).map(([name, value]) => ({ name, value }));

test('an accepted network command is not mistaken for a delivered reading', () => {
  const instance = 'atmos.alarm.e42';
  const request = {
    id: 1,
    line: `invoke ${instance} read reason=inspect`,
    pending: false,
    status: 'ok',
    error: null,
    records: [row({ operation: '987', status: 'sent' })],
  };
  expect(deviceReadState([request], instance)).toMatchObject({
    phase: 'queued', operation: '987', reading: null,
  });
  const waiting = {
    id: 2, line: 'result 987', pending: false, status: 'no_answer',
    error: null, records: [],
  };
  expect(deviceReadState([request, waiting], instance)).toMatchObject({
    phase: 'waiting', operation: '987', reading: null,
  });
  const response = {
    id: 3, line: 'result 987', pending: false, status: 'ok', error: null,
    records: [row({ pressureKPa: '101.3', temperatureK: '293.2', danger: '0', alarm: 'True' })],
  };
  expect(deviceReadState([request, waiting, response], instance)).toMatchObject({
    phase: 'ready', reading: {
      pressureKPa: 101.3, temperatureK: 293.2, alarm: true, danger: 0,
    },
  });
});

test('a response belongs to the selected device and to its most recent request', () => {
  const first = {
    id: 1, line: 'invoke atmos.alarm.e42 read reason=inspect', status: 'ok', pending: false, error: null,
    records: [row({ operation: '900' })],
  };
  const reply = {
    id: 2, line: 'result 900', status: 'ok', pending: false, error: null,
    records: [row({ pressureKPa: '90', temperatureK: '290', alarm: 'false', danger: '0' })],
  };
  const next = {
    id: 3, line: 'invoke atmos.alarm.e42 read reason=inspect', status: null, pending: true,
    error: null, records: [],
  };
  expect(deviceReadState([first, reply], 'atmos.alarm.another').phase).toBe('idle');
  expect(deviceReadState([first, reply, next], 'atmos.alarm.e42').phase).toBe('sending');
});

test('only actual delivered schema data produces a panel reading', () => {
  const events = [{
    instance: 'atmos.alarm.e42', schema: 'atmos.alarm_state',
    delivery: '55', payload: '{"pressureKPa":108.5,"temperatureK":320,"alarm":true,"danger":2}',
  }];
  expect(deviceLastEvent(events, 'atmos.alarm.e42')).toMatchObject({
    delivery: '55', reading: { pressureKPa: 108.5, temperatureK: 320, alarm: true, danger: 2 },
  });
  expect(alarmStateLabel(deviceLastEvent(events, 'atmos.alarm.e42')!.reading)).toBe('Тревога');
  expect(deviceLastEvent(events, 'atmos.alarm.e43')).toBeNull();
  expect(deviceLastEvent([{
    ...events[0], payload: '{"pressureKPa":"abc","temperatureK":320,"danger":2,"alarm":true}',
  }], 'atmos.alarm.e42')).toBeNull();
  expect(deviceLastEvent([{ ...events[0], payload: '{' }], 'atmos.alarm.e42')).toBeNull();
});

test('telemetry never infers that an unreported alarm is clear', () => {
  const reading = atmosReading({ pressureKPa: 101.3, temperatureK: 294, quality: 'current' });
  expect(reading).toMatchObject({ pressureKPa: 101.3, temperatureK: 294, alarm: null, danger: null });
  expect(alarmStateLabel(reading!)).toBe('Получены показания');
  expect(atmosReading({ pressureKPa: -30, temperatureK: 294 })).toBeNull();
  expect(atmosReading({ pressureKPa: NaN, temperatureK: 294 })).toBeNull();
});
