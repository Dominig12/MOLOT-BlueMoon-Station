import { nearbyDestinations } from './netdmPresenceNavigation';
import { parseView } from './NetdmTopology/model';

test('only currently known adjacent shells appear as local movement candidates', () => {
  const view = parseView({
    nodes: [['1', 1, 1, 0], ['2', 2, 1, 0], ['3', 3, 1, 0], ['4', 1, 2, 32]],
    edges: [['1', '2'], ['2', '3'], ['1', '4']],
  });
  const services = [
    { instance: 'shell.two', type: 'network.shell', node: '2', stale: false },
    { instance: 'shell.three', type: 'network.shell', node: '3', stale: false },
    { instance: 'shell.four', type: 'network.shell', node: '4', stale: false },
  ];
  expect(nearbyDestinations(view, '1', services)).toEqual([
    { node: '2', instance: 'shell.two', radio: false, unavailable: false },
    { node: '4', instance: 'shell.four', radio: false, unavailable: true },
  ]);
  expect(nearbyDestinations(view, '9', services)).toEqual([]);
  expect(nearbyDestinations(view, null, services)).toEqual([]);
});

test('broken or stale routes do not masquerade as available and duplicates are deduplicated', () => {
  const view = parseView({
    nodes: [['1', 1, 1, 0], ['2', 2, 1, 0], ['3', 1, 2, 0]],
    edges: [['1', '2']],
    radio: [['1', '2'], ['1', '3']],
    down: [['1', '3']],
  });
  expect(nearbyDestinations(view, '1', [
    { instance: 'shell.two', type: 'network.shell', node: '2', stale: false },
    { instance: 'shell.three', type: 'network.shell', node: '3', stale: true },
  ])).toEqual([
    { node: '2', instance: 'shell.two', radio: false, unavailable: false },
    { node: '3', instance: 'shell.three', radio: true, unavailable: true },
  ]);
});

test('ordinary devices never become move targets without an actual shell service', () => {
  const view = parseView({
    nodes: [['1', 1, 1, 0], ['2', 2, 1, 0]],
    edges: [['1', '2']],
  });
  expect(nearbyDestinations(view, '1', [
    { instance: 'atmos.two', type: 'atmos.alarm', node: '2', stale: false },
  ])).toEqual([]);
});
