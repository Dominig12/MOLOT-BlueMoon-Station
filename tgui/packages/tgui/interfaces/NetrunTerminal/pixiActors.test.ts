import { PixiActors } from './pixiActors';
import { GraphScene, PlacedNode } from './graphScene';

const node = (address: string, px: number): PlacedNode => ({
  address, name: address, type: 'apc', x: px, y: 0, px, py: 0,
  security: 1, access: 1, online: true, active: false, entities: 0,
  uplink: null,
});

class Shape {
  static all: Shape[] = [];
  calls: string[] = [];
  constructor() { Shape.all.push(this); }
  clear() { this.calls.push('clear'); return this; }
  moveTo() { this.calls.push('moveTo'); return this; }
  lineTo() { this.calls.push('lineTo'); return this; }
  stroke() { this.calls.push('stroke'); return this; }
  circle() { this.calls.push('circle'); return this; }
  rect() { this.calls.push('rect'); return this; }
  roundRect() { this.calls.push('roundRect'); return this; }
  fill() { this.calls.push('fill'); return this; }
  closePath() { this.calls.push('closePath'); return this; }
}
class Group {
  children: unknown[] = [];
  addChild(...children: unknown[]) { this.children.push(...children); }
}
class TextStub {
  text: string;
  position = { set: jest.fn() };
  visible = true;
  constructor(options: { text: string }) { this.text = options.text; }
}

const mockPixi = { Container: Group, Graphics: Shape, Text: TextStub } as unknown as typeof import('pixi.js');

describe('NetRun batched Pixi actor layer', () => {
  test('draws routes and transient markers without SVG nodes or sprites', () => {
    Shape.all = [];
    const scene = new GraphScene();
    scene.update([node('A', 0), { ...node('B', 100), dynamic: true, active: true,
      entities: 2, ice: 1 }], [{ id: 'e', from: 'A', to: 'B', kind: 'apc' }]);
    const overlay = {
      selected: 'A', entityHost: 'B', jacked: null, gateways: new Map(),
      selectedRoute: ['A', 'B'], waypointRoute: [], pingRoute: [], events: [
        { kind: 'intrusion' as const, from: 'A', to: 'B', age: 1 },
      ],
    };
    const adjacency = new Map([['A', new Set(['B'])], ['B', new Set(['A'])]]);
    const actors = new PixiActors(mockPixi);
    const before = Shape.all.length;
    expect(actors.update(scene, overlay, [], adjacency)).toBe(true);
    expect(Shape.all.length).toBe(before);
    expect(Shape.all.some((shape) => shape.calls.includes('circle'))).toBe(true);
    expect(Shape.all.some((shape) => shape.calls.includes('lineTo'))).toBe(true);
    // No new geometry if only the camera moves: retained batches are reused.
    expect(actors.update(scene, overlay, [], adjacency)).toBe(true);
  });

  test('unchanged overlay references skip all graphics rebuilds', () => {
    Shape.all = [];
    const scene = new GraphScene(); scene.update([node('A', 0)], []);
    const overlay = { selected: null, entityHost: null, jacked: null, gateways: new Map(),
      selectedRoute: [], waypointRoute: [], pingRoute: [], events: [] };
    const adjacency = new Map<string, Set<string>>();
    const dynamicEdges: [] = [];
    const actors = new PixiActors(mockPixi);
    expect(actors.update(scene, overlay, dynamicEdges, adjacency)).toBe(true);
    const calls = Shape.all.reduce((sum, shape) => sum + shape.calls.length, 0);
    expect(actors.update(scene, overlay, dynamicEdges, adjacency)).toBe(false);
    expect(Shape.all.reduce((sum, shape) => sum + shape.calls.length, 0)).toBe(calls);
  });
});
