import { isSelectedPreview, nodeTravelChoice } from './netdmNodeTravel';
import { parseView } from './NetdmTopology/model';

const view = parseView({
  nodes: [
    ['1', 1, 1, 0],
    ['2', 2, 1, 0],
    ['3', 3, 1, 32],
    ['4', 4, 1, 64],
    ['5', 5, 1, 0],
    ['6', 6, 1, 0],
  ],
  edges: [['1', '2'], ['2', '3'], ['3', '4'], ['4', '5']],
});
const services = [
  { node: '1', type: 'network.shell', instance: 'shell.home', stale: false },
  { node: '2', type: 'network.shell', instance: 'shell.remote', stale: false },
  { node: '3', type: 'network.shell', instance: 'shell.no_power', stale: false },
  { node: '4', type: 'network.shell', instance: 'shell.broken', stale: false },
  { node: '5', type: 'network.shell', instance: 'shell.old', stale: true },
  { node: '6', type: 'atmos.alarm', instance: 'sensor.other', stale: false },
];

test('selecting a node never invents a destination or ignores an offline/stale target', () => {
  expect(nodeTravelChoice(view, '1', '1', services)).toEqual({ state: 'here', instance: null });
  expect(nodeTravelChoice(view, '2', '1', services)).toEqual({ state: 'ready', instance: 'shell.remote' });
  expect(nodeTravelChoice(view, '3', '1', services)).toEqual({ state: 'offline', instance: null });
  expect(nodeTravelChoice(view, '4', '1', services)).toEqual({ state: 'offline', instance: null });
  expect(nodeTravelChoice(view, '5', '1', services)).toEqual({ state: 'stale', instance: null });
  expect(nodeTravelChoice(view, '6', '1', services)).toEqual({ state: 'no_shell', instance: null });
  expect(nodeTravelChoice(view, '999', '1', services)).toEqual({ state: 'unknown', instance: null });
  expect(nodeTravelChoice(view, null, '1', services)).toEqual({ state: 'unknown', instance: null });
});

test('a movement shortcut is only valid after Host confirms the selected exact target', () => {
  const ready = nodeTravelChoice(view, '2', '1', services);
  expect(isSelectedPreview(ready, { target: 'shell.remote', status: 'pending' })).toBe(false);
  expect(isSelectedPreview(ready, { target: 'shell.different', status: 'ready' })).toBe(false);
  expect(isSelectedPreview(ready, { target: 'shell.remote', status: 'ready' })).toBe(true);
  expect(isSelectedPreview(nodeTravelChoice(view, '5', '1', services), {
    target: 'shell.old', status: 'ready',
  })).toBe(false);
});
