import { fireEvent, render } from '@testing-library/react';

import { InfinitePlane } from './InfinitePlane';

test('wheel zoom keeps the point under the cursor fixed inside an offset canvas', () => {
  const onBackgroundMoved = jest.fn();
  const onZoomChange = jest.fn();
  const view = render(
    <InfinitePlane onBackgroundMoved={onBackgroundMoved} onZoomChange={onZoomChange} />,
  );
  const canvas = view.container.firstElementChild as HTMLElement;
  canvas.getBoundingClientRect = () => ({ left: 200, top: 100 } as DOMRect);
  fireEvent.wheel(canvas, { clientX: 300, clientY: 150, deltaY: -100 });
  expect(onZoomChange).toHaveBeenCalledWith(1.1);
  const [x, y] = onBackgroundMoved.mock.calls[0];
  expect(x).toBeCloseTo(-10);
  expect(y).toBeCloseTo(-5);
  expect((100 - x) / 1.1).toBeCloseTo(100);
  expect((50 - y) / 1.1).toBeCloseTo(50);
});

test('panning continues outside the canvas and stops on mouse release', () => {
  const onBackgroundMoved = jest.fn();
  const view = render(<InfinitePlane onBackgroundMoved={onBackgroundMoved} />);
  const background = view.container.firstElementChild.firstElementChild;
  fireEvent.mouseDown(background, { button: 2, clientX: 20, clientY: 30 });
  fireEvent.mouseMove(window, { clientX: 70, clientY: 90 });
  expect(onBackgroundMoved).toHaveBeenLastCalledWith(50, 60);
  fireEvent.mouseUp(window, { clientX: 70, clientY: 90 });
  onBackgroundMoved.mockClear();
  fireEvent.mouseMove(window, { clientX: 100, clientY: 100 });
  expect(onBackgroundMoved).not.toHaveBeenCalled();
});

test('fit-to-view zoom is not rounded and wheel over a value editor does not zoom', () => {
  const onZoomChange = jest.fn();
  const view = render(
    <InfinitePlane initialZoom={0.37} onZoomChange={onZoomChange}>
      <input aria-label="Port value" />
    </InfinitePlane>,
  );
  const plane = view.container.firstElementChild.children[1] as HTMLElement;
  expect(plane.style.transform).toContain('scale(0.37)');
  fireEvent.wheel(view.getByLabelText('Port value'), { deltaY: -100 });
  expect(onZoomChange).not.toHaveBeenCalled();
});
