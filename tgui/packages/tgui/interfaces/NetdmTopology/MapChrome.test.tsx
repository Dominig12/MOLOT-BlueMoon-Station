import { fireEvent, render, screen } from '@testing-library/react';

import { MapChrome } from './MapChrome';
import { parseView } from './model';

test('HUD and legend are independent of PixiJS and game commands', () => {
  const view = parseView({
    nodes: [['1', 10, 12, 16], ['2', 11, 12, 8]],
    edges: [['1', '2']],
    radio: [],
    down: [],
  });
  const toggle = jest.fn();
  const ui = render(<MapChrome level={2} nodeCount={2} linkCount={1}
    selected={view.nodes.get('2')} view={view} showLegend={false} onToggleLegend={toggle} />);
  expect(screen.getByText(/2 узлов/)).toBeTruthy();
  expect(screen.getByText(/X 11/)).toBeTruthy();
  fireEvent.click(screen.getByText('Легенда'));
  expect(toggle).toHaveBeenCalledTimes(1);
  ui.rerender(<MapChrome level={2} nodeCount={2} linkCount={1}
    selected={view.nodes.get('2')} view={view} showLegend onToggleLegend={toggle} />);
  expect(screen.getByText(/Проводные: 1/)).toBeTruthy();
});

test('игровая легенда включает только известные типы устройств текущего уровня', () => {
  const view = parseView({ nodes: [['1', 10, 12, 16], ['2', 11, 12, 8]] });
  render(<MapChrome level={2} nodeCount={2} linkCount={0} view={view} showLegend playerMap
    deviceServices={[{ node: '2', type: 'camera.access' }, { node: '3', type: 'machine.door' }]}
    onToggleLegend={jest.fn()} />);
  expect(screen.getByText('АПЦ')).toBeTruthy();
  expect(screen.getByText('Камера')).toBeTruthy();
  expect(screen.getByRole('button', { name: 'Легенда' }).getAttribute('aria-expanded')).toBe('true');
  expect(screen.queryByText('Дверь или шлюз')).toBeNull();
});
