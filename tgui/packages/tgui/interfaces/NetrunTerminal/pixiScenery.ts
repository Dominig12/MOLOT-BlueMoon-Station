import type { Container, Graphics } from 'pixi.js';

import { GRAPH_TILE } from './graphLayout';
import { boxesIntersect, GraphBase, GraphBox, markerColor, markerScale, physicalPoint, segmentBox } from './graphPresentation';
import type { GraphScene, PlacedNode } from './graphScene';
import { destroyDisplay, edgeColor, markerPath, pixiColor, PixiLibrary } from './pixiPrimitives';

type Stroke = { from: { px: number; py: number }; to: { px: number; py: number } };
type ZoneRect = { x: number; y: number; width: number };
type Batch = { key: string; nodes: PlacedNode[]; strokes: Stroke[]; zones: ZoneRect[];
  color: number; alpha: number; width: number; bounds: GraphBox; signature: string[] };
type RetainedBatch = { graphic: Graphics; signature: string; bounds: GraphBox };
const CELL = GRAPH_TILE * 8;
const EMPTY_BOUNDS = (): GraphBox => ({ left: Infinity, top: Infinity, right: -Infinity, bottom: -Infinity });
const include = (box: GraphBox, next: GraphBox) => {
  box.left = Math.min(box.left, next.left); box.right = Math.max(box.right, next.right);
  box.top = Math.min(box.top, next.top); box.bottom = Math.max(box.bottom, next.bottom);
};

/** World-coordinate Graphics batches survive camera movement and unrelated live updates. */
export class PixiScenery {
  readonly world: Container;
  private readonly layers: Container[];
  private readonly records = new Map<string, RetainedBatch>();
  private scene: GraphScene | null = null;
  private base: GraphBase | null = null;
  private scale = 1;
  private pending: Generator<void, void, unknown> | null = null;
  constructor(private readonly pixi: PixiLibrary) {
    this.world = new pixi.Container();
    this.world.label = 'netrun-scenery';
    this.layers = ['zones', 'cables', 'anchors', 'devices'].map((name) => {
      const layer = new pixi.Container(); layer.label = name; this.world.addChild(layer); return layer;
    });
  }

  queue(scene: GraphScene, base: GraphBase, force = false) {
    if (!force && this.scene === scene && this.base?.gateways === base.gateways
      && this.base?.apcZones === base.apcZones) { return false; }
    this.scene = scene; this.base = base;
    this.pending = this.build(scene, base);
    return true;
  }

  /** Small build slices leave the next render free for camera/hover/selection. */
  advance(budgetMs = 4) {
    const began = performance.now(); let work = 0;
    while (this.pending && (work === 0 || performance.now() - began < budgetMs) && work < 24) {
      if (this.pending.next().done) { this.pending = null; }
      work++;
    }
    return !!this.pending;
  }

  private* build(scene: GraphScene, base: GraphBase): Generator<void, void, unknown> {
    let work = 0;
    const batches = new Map<string, Batch>();
    const batch = (kind: string, x: number, y: number, color: number, alpha: number, width = 1) => {
      const prefix = `${kind}:${Math.floor(x / CELL)},${Math.floor(y / CELL)}:${color}:${alpha}:${width}`;
      let index = 0, key = `${prefix}:0`, result = batches.get(key);
      // Chunking limits tessellation per Graphics, never the number of displayed objects.
      while (result && result.nodes.length + result.strokes.length + result.zones.length >= 128) {
        key = `${prefix}:${++index}`; result = batches.get(key);
      }
      if (!result) {
        result = { key, nodes: [], strokes: [], zones: [], color, alpha, width, bounds: EMPTY_BOUNDS(), signature: [] };
        batches.set(key, result);
      }
      return result;
    };
    for (const zone of base.apcZones || []) {
      for (const run of zone.runs) {
        const x = (run.x - .5) * GRAPH_TILE, y = -(run.y + .5) * GRAPH_TILE, width = run.width * GRAPH_TILE;
        const item = batch('0-zone', x, y, 0x4095bc, .16);
        item.zones.push({ x, y, width }); item.signature.push(`${x},${y},${width}`);
        include(item.bounds, { left: x, right: x + width, top: y, bottom: y + GRAPH_TILE });
        if (++work % 128 === 0) { yield; }
      }
    }
    for (const edge of scene.edges) {
      const a = scene.byAddress.get(edge.from), b = scene.byAddress.get(edge.to);
      if (!a || !b || a.dynamic || b.dynamic) { continue; }
      const from = physicalPoint(a), to = physicalPoint(b);
      const item = batch('1-edge', from.px, from.py, edgeColor(edge.kind, edge.online !== false),
        edge.online === false ? .42 : edge.kind === 'endpoint' ? .6 : .9, edge.kind === 'endpoint' ? 1 : 1.6);
      item.strokes.push({ from, to }); item.signature.push(`${edge.id}:${from.px},${from.py},${to.px},${to.py}`);
      include(item.bounds, segmentBox(from, to));
      if (++work % 128 === 0) { yield; }
    }
    for (const node of scene.nodes) {
      if (node.dynamic) { continue; }
      const anchor = physicalPoint(node);
      if (anchor.px !== node.px || anchor.py !== node.py) {
        const item = batch('2-anchor', node.px, node.py, 0x75a3b4, .4);
        item.strokes.push({ from: anchor, to: node }); item.signature.push(`${anchor.px},${anchor.py},${node.px},${node.py}`);
        include(item.bounds, segmentBox(anchor, node));
      }
      const fill = pixiColor(markerColor(node), 0x678698);
      const border = pixiColor(base.gateways.get(node.network)?.color, 0x527287);
      const item = batch('3-node', node.px, node.py, fill, 1);
      item.nodes.push(node); item.signature.push(`${node.address}:${node.px},${node.py}:${node.type}:${border}:${this.scale}`);
      const emphasized = node.type === 'gateway' || node.type === 'relay';
      const radius = emphasized ? 19 * this.scale : 16;
      include(item.bounds, { left: node.px - radius, right: node.px + radius, top: node.py - radius, bottom: node.py + radius });
      if (++work % 128 === 0) { yield; }
    }
    for (const [key, data] of batches) {
      const signature = `${data.width}:${data.signature.join('|')}`;
      let retained = this.records.get(key);
      if (!retained) {
        const graphic = new this.pixi.Graphics(); graphic.label = key;
        this.layers[Number(key[0])].addChild(graphic);
        retained = { graphic, signature: '', bounds: data.bounds }; this.records.set(key, retained);
      }
      retained.bounds = data.bounds;
      if (retained.signature === signature) { continue; }
      retained.signature = signature;
      const graphic = retained.graphic; graphic.clear();
      for (const rect of data.zones) { graphic.rect(rect.x, rect.y, rect.width, GRAPH_TILE); }
      if (data.zones.length) { graphic.fill({ color: data.color, alpha: data.alpha }); }
      for (const stroke of data.strokes) { graphic.moveTo(stroke.from.px, stroke.from.py).lineTo(stroke.to.px, stroke.to.py); }
      if (data.strokes.length) { graphic.stroke({ color: data.color, width: data.width, alpha: data.alpha }); }
      for (const node of data.nodes) {
        const border = pixiColor(base.gateways.get(node.network)?.color, 0x527287);
        // Ordinary devices shrink naturally with zoom. Only LAN gateway
        // markers retain a visible outline in the far-out overview.
        markerPath(graphic, node.type, node.px, node.py, 1)
          .fill({ color: data.color, alpha: .94 })
          .stroke({ color: border, width: 1.5 });
        if (node.type === 'gateway' || node.type === 'relay') {
          graphic.circle(node.px, node.py, 19 * this.scale)
            .stroke({ color: border, width: Math.min(3, 1.3 * this.scale), alpha: .64 });
        }
        if (['apc', 'server', 'terminal', 'camera'].includes(node.type)) {
          graphic.moveTo(node.px - 4, node.py).lineTo(node.px + 4, node.py);
          if (node.type === 'apc') { graphic.moveTo(node.px, node.py - 4).lineTo(node.px, node.py + 4); }
          graphic.stroke({ color: 0x102331, width: 1.5 });
        }
      }
      yield;
    }
    for (const [key, item] of this.records) {
      if (!batches.has(key)) { destroyDisplay(item.graphic); this.records.delete(key); }
    }
  }

  setViewport(bounds: GraphBox, zoom: number) {
    const next = markerScale(zoom);
    if (this.scale !== next) {
      this.scale = next;
      if (this.scene && this.base) { this.queue(this.scene, this.base, true); }
    }
    for (const item of this.records.values()) { item.graphic.visible = boxesIntersect(item.bounds, bounds); }
  }

  destroy() { this.pending = null; this.records.clear(); this.scene = null; this.base = null; destroyDisplay(this.world); }
}
