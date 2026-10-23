import type { Container, Graphics } from 'pixi.js';

import { GRAPH_TILE } from './graphLayout';
import { boxesIntersect, GraphBase, GraphBox, markerColor, physicalPoint, segmentBox } from './graphPresentation';
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
  private readonly prepared = new Map<string, { batch: Batch; signature: string }>();
  private readonly waiting = new Set<string>();
  private viewport: GraphBox | null = null;
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

  /** Build descriptors in bounded slices, then upload only newly visible GPU chunks. */
  advance(budgetMs = 4) {
    const began = performance.now(); let work = 0;
    while (this.pending && (work === 0 || performance.now() - began < budgetMs) && work < 24) {
      if (this.pending.next().done) { this.pending = null; }
      work++;
    }
    while (!this.pending && this.waiting.size && (work === 0 || performance.now() - began < budgetMs) && work < 24) {
      const key = this.waiting.values().next().value as string;
      this.waiting.delete(key);
      const prepared = this.prepared.get(key);
      if (prepared && (!this.viewport || boxesIntersect(prepared.batch.bounds, this.viewport))) {
        this.paint(prepared.batch, prepared.signature);
      }
      work++;
    }
    return !!this.pending || this.waiting.size > 0;
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
      item.nodes.push(node); item.signature.push(`${node.address}:${node.px},${node.py}:${node.type}:${border}`);
      include(item.bounds, { left: node.px - 16, right: node.px + 16, top: node.py - 16, bottom: node.py + 16 });
      if (++work % 128 === 0) { yield; }
    }
    // Commit prepared descriptors atomically. Existing graphics survive until
    // a changed visible chunk is ready; offscreen chunks do not consume GPU memory.
    this.prepared.clear();
    for (const [key, data] of batches) {
      this.prepared.set(key, { batch: data, signature: `${data.width}:${data.signature.join('|')}` });
    }
    for (const [key, retained] of this.records) {
      if (!this.prepared.has(key)) { destroyDisplay(retained.graphic); this.records.delete(key); }
    }
    this.enqueueVisible();
  }

  private enqueueVisible() {
    for (const [key, { batch, signature }] of this.prepared) {
      const visible = !this.viewport || boxesIntersect(batch.bounds, this.viewport);
      const retained = this.records.get(key);
      if (retained) { retained.graphic.visible = visible && retained.signature === signature; }
      if (visible && (!retained || retained.signature !== signature)) { this.waiting.add(key); }
      else { this.waiting.delete(key); }
    }
  }

  private paint(data: Batch, signature: string) {
    let retained = this.records.get(data.key);
    if (!retained) {
      const graphic = new this.pixi.Graphics(); graphic.label = data.key;
      this.layers[Number(data.key[0])].addChild(graphic);
      retained = { graphic, signature: '', bounds: data.bounds };
      this.records.set(data.key, retained);
    }
    retained.bounds = data.bounds;
    retained.graphic.visible = true;
    if (retained.signature === signature) { return; }
    retained.signature = signature;
    const graphic = retained.graphic;
    graphic.clear();
    for (const rect of data.zones) { graphic.rect(rect.x, rect.y, rect.width, GRAPH_TILE); }
    if (data.zones.length) { graphic.fill({ color: data.color, alpha: data.alpha }); }
    for (const stroke of data.strokes) { graphic.moveTo(stroke.from.px, stroke.from.py).lineTo(stroke.to.px, stroke.to.py); }
    if (data.strokes.length) { graphic.stroke({ color: data.color, width: data.width, alpha: data.alpha }); }
    const base = this.base!;
    for (const node of data.nodes) {
      const border = pixiColor(base.gateways.get(node.network)?.color, 0x527287);
      markerPath(graphic, node.type, node.px, node.py, 1)
        .fill({ color: data.color, alpha: .94 })
        .stroke({ color: border, width: 1.5 });
      // LAN outlines live in PixiActors; their zoom never retessellates this map.
      if (['apc', 'server', 'terminal', 'camera'].includes(node.type)) {
        graphic.moveTo(node.px - 4, node.py).lineTo(node.px + 4, node.py);
        if (node.type === 'apc') { graphic.moveTo(node.px, node.py - 4).lineTo(node.px, node.py + 4); }
        graphic.stroke({ color: 0x102331, width: 1.5 });
      }
    }
  }

  /** Moving or zooming the camera changes visibility, not batch geometry. */
  setViewport(bounds: GraphBox, _zoom: number) {
    this.viewport = bounds;
    this.enqueueVisible();
  }

  destroy() { this.pending = null; this.waiting.clear(); this.prepared.clear(); this.records.clear(); this.scene = null; this.base = null; destroyDisplay(this.world); }
}
