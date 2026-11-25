import {
  actionFields,
  argumentError,
  invocationLine,
  isReadAction,
  latestApiReply,
  safeServiceIdentifier,
  serviceActions,
} from './NetdmServiceSchema';

const fields = (record: Record<string, string>) =>
  Object.entries(record).map(([name, value]) => ({ name, value }));
const reply = (line: string, records: Record<string, string>[], id = 1) => ({
  id, line, records: records.map(fields), status: 'ok', pending: false, error: null,
});

test('catalogue is derived from the actual Host api reply and not guessed from service type', () => {
  const entry = reply('api machine.control', [
    { type: 'machine.control', command: 'set_power', request: 'machine.set_power', result: 'machine.power_state' },
    { type: 'other.type', command: 'erase', request: '', result: '' },
    { type: 'machine.control', command: 'set_power', request: '', result: '' },
    { type: 'machine.control', command: 'bad|command', request: '', result: '' },
  ]);
  expect(serviceActions(entry, 'machine.control')).toMatchObject([{
    command: 'set_power', request: 'machine.set_power',
  }]);
  expect(serviceActions(entry, 'other.type')).toEqual([]);
  expect(serviceActions({ ...entry, pending: true }, 'machine.control')).toEqual([]);
  expect(latestApiReply([entry, { ...entry, id: 2 }], 'api machine.control')?.id).toBe(2);
});

test('typed requests verify required args, enums, booleans and safe numeric ranges', () => {
  const fieldsList = actionFields(reply('api machine.door set_state', [
    { how: 'request', field: 'press', type: 'text', required: 'yes', spec: ' ≤64' },
    { how: 'request', field: 'state', type: 'enum', required: 'no', spec: '=open|closed' },
    { how: 'request', field: 'bolted', type: 'boolean', required: 'no', spec: '' },
    { how: 'result', field: 'changed', type: 'boolean', required: 'yes', spec: '' },
  ]), 'machine.door', 'set_state');
  expect(fieldsList).toHaveLength(3);
  expect(argumentError(fieldsList[0], '')).toBe('Обязательное поле');
  expect(argumentError(fieldsList[0], 'switch|shutdown')).not.toBeNull();
  expect(argumentError(fieldsList[1], 'broken')).not.toBeNull();
  expect(argumentError(fieldsList[2], 'yes')).not.toBeNull();
  expect(invocationLine('machine.door.e9', 'set_state', fieldsList, {
    press: 'button-51', state: 'closed', bolted: 'true',
  })).toBe('invoke machine.door.e9 set_state press=button-51 state=closed bolted=true');
  expect(invocationLine('machine.door.e9', 'set_state', fieldsList, {
    press: 'button-51 | publish', state: 'closed',
  })).toBeNull();
  expect(safeServiceIdentifier('machine.door.e9')).toBe(true);
  expect(safeServiceIdentifier('machine.door.e9 | publish')).toBe(false);
});

test('numeric fields have bounds and zero-argument read-only requests remain valid', () => {
  const schema = actionFields(reply('api research.server research', [
    { how: 'request', field: 'quote', type: 'integer', required: 'yes', spec: ' [0..1000000000]' },
  ]), 'research.server', 'research');
  expect(argumentError(schema[0], '-1')).not.toBeNull();
  expect(argumentError(schema[0], '3.5')).not.toBeNull();
  expect(argumentError(schema[0], '7')).toBeNull();
  expect(invocationLine('research.server.alpha', 'status', [], {}))
    .toBe('invoke research.server.alpha status');
  expect(isReadAction('status')).toBe(true);
  expect(isReadAction('set_power')).toBe(false);
  expect(isReadAction('delete_all')).toBe(false);
});

test.each([' open|closed', '=open|closed'])('enum choices survive compact Host encoding (%s)', spec => {
  const schema = actionFields(reply('api machine.door set_state', [
    { how: 'request', field: 'state', type: 'enum', required: 'no', spec },
  ]), 'machine.door', 'set_state');
  expect(schema[0].choices).toEqual(['open', 'closed']);
  expect(argumentError(schema[0], 'open')).toBeNull();
  expect(argumentError(schema[0], 'toggle')).not.toBeNull();
});
