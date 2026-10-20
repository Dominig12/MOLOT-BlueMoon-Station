import { fireEvent, render } from '@testing-library/react';
import { combineReducers, createStore, setGlobalStore } from 'common/redux';

import { backendReducer, backendUpdate } from '../../backend';
import { IntegratedCircuit } from './index';

const mockAct = jest.fn();
jest.mock('../../backend', () => {
  const backend = jest.requireActual('../../backend');
  return {
    ...backend,
    useBackend: () => ({ ...backend.useBackend(), act: mockAct }),
  };
});

// The native BYOND window lifecycle is outside the editor interaction tests.
jest.mock('../../layouts', () => {
  const Window = ({ children, buttons }) => <div>{buttons}{children}</div>;
  Window.Content = ({ children }) => <div>{children}</div>;
  return { Window };
});

const setupEditor = () => {
  const store = createStore(combineReducers({ backend: backendReducer }));
  setGlobalStore(store);
  store.dispatch(backendUpdate({
    config: { interface: 'IntegratedCircuit' },
    data: {
      ie_circuit: true,
      ie_clone_copy_mode: 'assembly',
      display_name: 'Test assembly',
      components: ['Sensor', 'Display'].map((name, index) => ({
        name, x: index * 200, y: 0, removable: true,
        input_ports: [], output_ports: [],
      })),
    },
  }));
};

test('search filters while typing, matches component numbers and can be cleared', () => {
  setupEditor();
  const view = render(<IntegratedCircuit />);
  const input = view.getByPlaceholderText('Найти имя или номер…');
  fireEvent.input(input, { target: { value: 'Sensor' } });
  expect(view.container.querySelectorAll('.IntegratedCircuit__componentRow')).toHaveLength(1);
  expect(view.container.querySelector('.IntegratedCircuit__componentRow').textContent).toContain('Sensor');
  fireEvent.input(input, { target: { value: '2' } });
  expect(view.container.querySelector('.IntegratedCircuit__componentRow').textContent).toContain('Display');
  expect(view.container.querySelector('.ObjectComponent--spotlit').textContent).toContain('Display');
  fireEvent.blur(input);
  fireEvent.click(view.getByText(/Сбросить поиск/));
  expect(view.container.querySelectorAll('.IntegratedCircuit__componentRow')).toHaveLength(2);
});

test('component navigation remains available after closing the sidebar', () => {
  setupEditor();
  const view = render(<IntegratedCircuit />);
  fireEvent.click(view.getByText('Компоненты'));
  expect(view.container.querySelector('.IntegratedCircuit__componentsPanel')).toBeNull();
  fireEvent.input(view.getByPlaceholderText('Найти имя или номер…'), {
    target: { value: 'Display' },
  });
  expect(view.container.querySelector('.IntegratedCircuit__componentsPanel')).not.toBeNull();
  expect(view.container.querySelectorAll('.IntegratedCircuit__componentRow')).toHaveLength(1);
});

test('node title drags with the left button, while body and controls do not', () => {
  setupEditor();
  const view = render(<IntegratedCircuit />);
  const node = view.container.querySelector('.ObjectComponent__root');
  const title = node.querySelector('.ObjectComponent__titleText');
  for (const target of [node, node.querySelector('.Button')]) {
    fireEvent.mouseDown(target, { button: 0, clientX: 10, clientY: 10 });
    fireEvent.mouseMove(window, { clientX: 42, clientY: 26 });
    fireEvent.mouseUp(window, { clientX: 42, clientY: 26 });
  }
  fireEvent.mouseDown(title, { button: 2, clientX: 10, clientY: 10 });
  fireEvent.mouseMove(window, { clientX: 42, clientY: 26 });
  fireEvent.mouseUp(window, { clientX: 42, clientY: 26 });
  expect(mockAct).not.toHaveBeenCalled();
  fireEvent.mouseDown(title, { button: 0, clientX: 10, clientY: 10 });
  fireEvent.mouseMove(window, { clientX: 42, clientY: 26 });
  expect(parseFloat((node as HTMLElement).style.left)).toBeCloseTo(32 / 12);
  fireEvent.mouseUp(window, { clientX: 58, clientY: 42 });
  expect(mockAct).toHaveBeenCalledWith('set_component_coordinates', {
    component_id: 1, rel_x: 48, rel_y: 32,
  });
});

test('modifier selection uses current state and group drag preserves spacing', () => {
  setupEditor();
  const view = render(<IntegratedCircuit />);
  const titles = view.container.querySelectorAll('.ObjectComponent__titleText');
  fireEvent.mouseDown(titles[0], { button: 0 });
  fireEvent.mouseUp(window);
  fireEvent.mouseDown(titles[1], { button: 0, ctrlKey: true });
  fireEvent.mouseUp(window);
  expect(view.container.querySelectorAll('.ObjectComponent--selected')).toHaveLength(2);
  fireEvent.mouseDown(titles[0], { button: 0, ctrlKey: true });
  fireEvent.mouseMove(window, { clientX: 32, clientY: 32 });
  fireEvent.mouseUp(window, { clientX: 32, clientY: 32 });
  expect(mockAct).not.toHaveBeenCalled();
  expect(view.container.querySelectorAll('.ObjectComponent--selected')).toHaveLength(1);
  fireEvent.mouseDown(titles[0], { button: 0, ctrlKey: true });
  fireEvent.mouseDown(titles[0], { button: 0 });
  fireEvent.mouseMove(window, { clientX: 32, clientY: 16 });
  fireEvent.mouseUp(window, { clientX: 32, clientY: 16 });
  expect(mockAct).toHaveBeenCalledWith('set_component_coordinates', {
    component_id: 1, rel_x: 32, rel_y: 16,
  });
  expect(mockAct).toHaveBeenCalledWith('set_component_coordinates', {
    component_id: 2, rel_x: 232, rel_y: 16,
  });
});

test('Escape cancels dragging without saving coordinates', () => {
  setupEditor();
  const view = render(<IntegratedCircuit />);
  fireEvent.mouseDown(view.container.querySelector('.ObjectComponent__titleText'), { button: 0 });
  fireEvent.mouseMove(window, { clientX: 32, clientY: 16 });
  fireEvent.keyDown(window, { key: 'Escape' });
  fireEvent.mouseUp(window, { clientX: 32, clientY: 16 });
  expect(mockAct).not.toHaveBeenCalled();
  expect(parseFloat((view.container.querySelector('.ObjectComponent__root') as HTMLElement).style.left)).toBe(0);
});

test('minimap dragging right and down moves the viewport right and down', () => {
  setupEditor();
  const view = render(<IntegratedCircuit />);
  fireEvent.mouseDown(view.container.querySelector('.ObjectComponent__titleText'), { button: 0 });
  fireEvent.mouseUp(window);
  fireEvent.mouseDown(view.container.querySelector('.IntegratedCircuit__minimap'), {
    button: 0, clientX: 40, clientY: 40,
  });
  fireEvent.mouseMove(window, { clientX: 60, clientY: 50 });
  fireEvent.mouseUp(window, { clientX: 60, clientY: 50 });
  const [action, position] = mockAct.mock.calls[mockAct.mock.calls.length - 1];
  expect(action).toBe('move_screen');
  // Camera moves in positive world coordinates; canvas translation is negative.
  expect(position.screen_x).toBeLessThan(0);
  expect(position.screen_y).toBeLessThan(0);
  expect(view.container.querySelectorAll('.ObjectComponent--selected')).toHaveLength(1);
});

test('small click movement does not snap a node and Alt allows precise placement', () => {
  setupEditor();
  const view = render(<IntegratedCircuit />);
  const title = view.container.querySelectorAll('.ObjectComponent__titleText')[1];
  fireEvent.mouseDown(title, { button: 0 });
  fireEvent.mouseUp(window, { clientX: 1, clientY: 1 });
  expect(mockAct).not.toHaveBeenCalled();
  fireEvent.mouseDown(title, { button: 0 });
  fireEvent.mouseUp(window, { clientX: 5, clientY: 7, altKey: true });
  expect(mockAct).toHaveBeenCalledWith('set_component_coordinates', {
    component_id: 2, rel_x: 205, rel_y: 7,
  });
});

test('unmounting during a minimap drag removes its window handlers', () => {
  setupEditor();
  const view = render(<IntegratedCircuit />);
  fireEvent.mouseDown(view.container.querySelector('.IntegratedCircuit__minimap'), {
    button: 0, clientX: 40, clientY: 40,
  });
  view.unmount();
  fireEvent.mouseMove(window, { clientX: 60, clientY: 50 });
  fireEvent.mouseUp(window, { clientX: 60, clientY: 50 });
  expect(mockAct).not.toHaveBeenCalled();
});

test('Ctrl-drag in an assembly selects a rectangle without inserting a chip', () => {
  setupEditor();
  const view = render(<IntegratedCircuit />);
  const background = view.container.querySelector('.IntegratedCircuit__canvas').firstElementChild;
  fireEvent.mouseDown(background, { button: 0, ctrlKey: true, clientX: 0, clientY: 0 });
  fireEvent.mouseMove(window, { clientX: 30, clientY: 30 });
  expect(view.container.querySelector('.IntegratedCircuit__marquee')).not.toBeNull();
  fireEvent.mouseUp(window, { clientX: 30, clientY: 30 });
  expect(mockAct).not.toHaveBeenCalled();
  expect(view.container.querySelectorAll('.ObjectComponent--selected')).toHaveLength(2);
});
