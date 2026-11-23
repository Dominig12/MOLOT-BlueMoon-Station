import { BooleanLike } from 'common/react';

/**
 * A view of acknowledged shell replies and delivered events. No optimistic network state,
 * timers, retries or commands are triggered while deriving these values.
 */
export type DeviceRecord = { name: string; value: string };
export type DeviceEntry = {
  id: number;
  line: string;
  pending: BooleanLike;
  status: string | null;
  error: string | null;
  records: DeviceRecord[][];
  delivery?: {
    state: 'queued' | 'applied' | 'delivered' | 'rejected' | 'not_delivered' | 'unknown';
    operation: string;
    instance: string;
    reason?: string | null;
  } | null;
};
export type DeviceEvent = {
  instance: string;
  schema: string;
  payload: string;
  delivery: string;
};

export type AtmosReading = {
  pressureKPa: number;
  temperatureK: number;
  danger: number | null;
  alarm: boolean | null;
};

export type ReadPhase = 'idle' | 'sending' | 'queued' | 'checking' | 'ready' | 'waiting' | 'failed';
export type ReadState = {
  phase: ReadPhase;
  operation: string | null;
  reading: AtmosReading | null;
  error: string | null;
};

const field = (record: DeviceRecord[], name: string) =>
  record.find(cell => cell.name === name)?.value;

const numeric = (value: unknown): number | null => {
  if ((typeof value !== 'number' && typeof value !== 'string') ||
      value === '' || (typeof value === 'string' && !value.trim())) {
    return null;
  }
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 && parsed <= 1000000 ? parsed : null;
};

const boolValue = (value: unknown): boolean | null => {
  if (value === true || value === 1 || value === '1') return true;
  if (value === false || value === 0 || value === '0') return false;
  if (typeof value === 'string') {
    if (value.toLowerCase() === 'true') return true;
    if (value.toLowerCase() === 'false') return false;
  }
  return null;
};

export const atmosReading = (fields: Record<string, unknown>): AtmosReading | null => {
  const pressureKPa = numeric(fields.pressureKPa);
  const temperatureK = numeric(fields.temperatureK);
  if (pressureKPa === null || temperatureK === null) return null;
  const alarm = boolValue(fields.alarm);
  const dangerValue = numeric(fields.danger);
  const danger = dangerValue !== null && Number.isInteger(dangerValue) && dangerValue <= 2
    ? dangerValue : null;
  return { pressureKPa, temperatureK, danger, alarm };
};

const readRecords = (entry: DeviceEntry | undefined): AtmosReading | null => {
  if (!entry || entry.pending || entry.status !== 'ok') return null;
  for (const record of entry.records) {
    const parsed = atmosReading(Object.fromEntries(record.map(cell => [cell.name, cell.value])));
    if (parsed) return parsed;
  }
  return null;
};

export const deviceReadState = (entries: DeviceEntry[], instance: string): ReadState => {
  const requestLine = `invoke ${instance} read reason=inspect`;
  const request = [...entries].reverse().find(entry => entry.line === requestLine);
  if (!request) return { phase: 'idle', operation: null, reading: null, error: null };
  if (request.pending) return { phase: 'sending', operation: null, reading: null, error: null };
  if (request.status !== 'ok') {
    return { phase: 'failed', operation: null, reading: null, error: request.error ?? request.status };
  }

  const operation = request.records.map(record => field(record, 'operation'))
    .find(value => value && /^[1-9][0-9]{0,17}$/.test(value)) ?? null;
  if (!operation) {
    return { phase: 'failed', operation: null, reading: null, error: 'Номер сетевой операции не получен' };
  }

  const result = [...entries].reverse().find(entry =>
    entry.id > request.id && entry.line === `result ${operation}`);
  if (!result) return { phase: 'queued', operation, reading: null, error: null };
  if (result.pending) return { phase: 'checking', operation, reading: null, error: null };
  if (result.status !== 'ok') {
    // The Host can legitimately have no delivered result yet; the user may check again.
    return { phase: 'waiting', operation, reading: null, error: result.error ?? null };
  }
  const reading = readRecords(result);
  return reading
    ? { phase: 'ready', operation, reading, error: null }
    : { phase: 'waiting', operation, reading: null, error: 'Нет подтверждённых показаний' };
};

/** A historic event is never called a fresh/current device state. */
export const deviceLastEvent = (events: DeviceEvent[], instance: string): {
  reading: AtmosReading;
  delivery: string;
  schema: string;
} | null => {
  for (let index = events.length - 1; index >= 0; index--) {
    const event = events[index];
    if (event.instance !== instance ||
        !['atmos.alarm_state', 'atmos.sample'].includes(event.schema)) continue;
    try {
      const payload: unknown = JSON.parse(event.payload);
      if (!payload || typeof payload !== 'object' || Array.isArray(payload)) continue;
      const reading = atmosReading(payload as Record<string, unknown>);
      if (reading) return { reading, delivery: event.delivery, schema: event.schema };
    } catch {
      // Malformed deliveries must not invent a device state or break the interface.
    }
  }
  return null;
};

export const alarmStateLabel = (reading: AtmosReading): string => {
  if (reading.alarm === true || reading.danger === 2) return 'Тревога';
  if (reading.danger === 1) return 'Предупреждение';
  if (reading.alarm === false && reading.danger === 0) return 'Без тревоги';
  return 'Получены показания';
};
