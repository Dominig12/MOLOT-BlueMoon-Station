/**
 * PixiJS adapter of the netDM topology screen.
 *
 * One screen owns one Application for its whole life. Updates change display objects by ID;
 * nothing is rebuilt and the viewport survives. Rendering happens on demand (no ticker loop).
 * The renderer never decides reachability: it draws what the Host reported.
 */
// Named imports let the bundler drop the parts of PixiJS this screen does not use.
import { Application, Container, Graphics, GraphicsContext, Text } from 'pixi.js';

import {
  diffById,
  fitView,
  FLAG_DEVICE,
  FLAG_RADIO,
  isOffline,
  kindOf,
  nearestNode,
  sameLink,
  sameNode,
  screenToWorld,
  TILE,
  toWorld,
  View,
  ViewLink,
  ViewNode,
  Viewport,
  zoomAt,
} from './model';

export type SceneCallbacks = {
  onSelect: (id: string | null) => void;
  onFailure: (reason: string) => void;
};

export type SceneFilters = {
  radio: boolean;
  devices: boolean;
};

export type NodePresenceCounts = Readonly<Record<string, number>>;

/** How many recent network events touched each node of the level. */
export type NodeActivityCounts = Readonly<Record<string, number>>;

/** P13: one network entity standing on a level node. */
export type SceneAgent = { node: string; goal: string; label: string };

/** P13: another operator's presence on a level node. */
export type SceneOperator = { node: string; label: string; colour: number };

/** A null slot is an undisclosed hop. The segments on either side stay separate. */
export type SceneRoute = {
  nodes: readonly (string | null)[];
  radioLegs: readonly number[];
  moving: boolean;
  broken?: boolean;
};

export interface TopologyScene {
  /** Renderer backend the client actually got: 'webgl', 'webgpu' or 'canvas'. */
  readonly backend: string;
  /** Applies a snapshot as deltas; a new `levelKey` refits the viewport once. */
  update(view: View, levelKey: string): void;
  setSelection(id: string | null): void;
  setPresence(id: string | null): void;
  setOtherPresences(counts: NodePresenceCounts | null): void;
  /** P13: nodes where something just happened in the network. */
  setActivity(counts: NodeActivityCounts | null): void;
  /** P13: agents (NPC entities) on the visible level. */
  setAgents(agents: readonly SceneAgent[] | null): void;
  /** P13: other operators in the network on the visible level. */
  setOperators(operators: readonly SceneOperator[] | null): void;
  setRoute(route: SceneRoute | null): void;
  setFilters(filters: SceneFilters): void;
  fit(): void;
  destroy(): void;
}

export class SceneCancelled extends Error {
  constructor() {
    super('scene_cancelled');
  }
}

type Style = 'apc' | 'wired' | 'radio' | 'node' | 'apcOffline' | 'nodeOffline';

const ACTIVITY_PULSE_MS = 6000;

const COLORS = {

  background: 0x101217,
  apc: 0x4a9eff,
  wired: 0x57c785,
  radio: 0xf0a040,
  node: 0x8b93a3,
  offline: 0x4b5263,
  wire: 0x6f7c99,
  silent: 0x6f7c99,
  air: 0xf0a040,
  selection: 0xffffff,
  presence: 0x55e7d0,
  otherPresence: 0xd19aff,
  activity: 0x78d9ec,
  agent: 0xe8b24a,
  operatorRing: 0xffffff,
  preview: 0xffc36a,
  routeBreak: 0xff6868,
};

/** P13: persona colours, indexed by the numeric colour a persona stores (0-7). */
const OPERATOR_COLOURS = [0x6ec6ff, 0xffd166, 0x8ce99a, 0xff9f6e, 0xd0a9ff, 0xff8fa3, 0x74d3c0, 0xf2f2f2];

/** Offline nodes keep their shape (square APC, round device) in a muted color. */
const styleOf = (flags: number): Style => {
  const kind = kindOf(flags);
  if (isOffline(flags)) {
    return kind === 'apc' ? 'apcOffline' : 'nodeOffline';
  }
  if (kind !== 'device') {
    return kind;
  }
  return flags & FLAG_RADIO ? 'radio' : 'wired';
};

/** Screen pixels a node keeps at any zoom, so a fitted station stays readable. */
const NODE_PIXELS = 5;
/** Pointer travel in pixels up to which a press is a click (select), not a drag (pan). */
const CLICK_TRAVEL = 4;

class PixiTopologyScene implements TopologyScene {
  private readonly nodes = new Map<string, { data: ViewNode; graphic: Graphics }>();
  private readonly links = new Map<string, { data: ViewLink; graphic: Graphics }>();
  private readonly otherPresenceGraphic = new Graphics();
  private readonly activityGraphic = new Graphics();
  private readonly agentGraphic = new Graphics();
  private readonly operatorGraphic = new Graphics();
  private readonly labelLayer = new Container();
  private readonly labels = new Map<string, Text>();
  private operators: readonly SceneOperator[] | null = null;
  private activity: NodeActivityCounts | null = null;
  private agents: readonly SceneAgent[] | null = null;
  private pulseFrame = 0;
  private pulseStart = 0;
  private pulsePhase = 0;
  private view: Viewport = { x: 0, y: 0, scale: 1 };
  private levelKey: string | null = null;
  private fitted = false;
  /**
   * The viewport follows "fit" until the user pans or zooms. A resize then refits: the canvas
   * can start before the window layout settles, and a fit at that size would stick otherwise.
   * Data updates never refit.
   */
  private autoFit = true;
  private selected: string | null = null;
  private presenceNode: string | null = null;
  private otherPresences: NodePresenceCounts | null = null;
  private route: SceneRoute | null = null;
  private filters: SceneFilters = { radio: true, devices: true };
  private frame = 0;
  /** Coalesces ResizeObserver notifications into one layout pass per frame. */
  private resizeFrame = 0;
  private destroyed = false;
  private drag: { x: number; y: number; travel: number } | null = null;
  private readonly observer: ResizeObserver | null;
  private readonly listeners: [string, EventListener, AddEventListenerOptions?][] = [];

  constructor(
    private readonly app: Application,
    private readonly host: HTMLElement,
    private readonly callbacks: SceneCallbacks,
    private readonly world: Container,
    private readonly linkLayer: Container,
    private readonly nodeLayer: Container,
    private readonly routeGraphic: Graphics,
    private readonly selection: Graphics,
    private readonly presence: Graphics,
    private readonly contexts: Record<Style, GraphicsContext>,
  ) {
    world.addChild(this.otherPresenceGraphic);
    world.addChild(this.activityGraphic);
    world.addChild(this.agentGraphic);
    world.addChild(this.operatorGraphic);
    world.addChild(this.labelLayer);
    const canvas = app.canvas as HTMLCanvasElement;
    canvas.style.display = 'block';
    canvas.style.touchAction = 'none';
    host.appendChild(canvas);
    this.listen('wheel', this.onWheel as EventListener, { passive: false });
    this.listen('pointerdown', this.onPointerDown as EventListener);
    this.listen('pointermove', this.onPointerMove as EventListener);
    this.listen('pointerup', this.onPointerUp as EventListener);
    this.listen('pointercancel', this.onPointerCancel as EventListener);
    this.listen('webglcontextlost', this.onContextLost as EventListener);
    this.observer = typeof ResizeObserver === 'undefined' ? null : new ResizeObserver(() => {
      // A resize handler that resizes the observed element in the same frame triggers the browser's
      // "ResizeObserver loop completed" error, which TGUI reports as a crash. Defer to the next frame
      // and coalesce bursts: the canvas then sees one settled size.
      if (this.resizeFrame) {
        return;
      }
      this.resizeFrame = requestAnimationFrame(() => {
        this.resizeFrame = 0;
        this.resize();
      });
    });
    this.observer?.observe(host);
  }

  get backend() {
    return this.app.renderer.name;
  }

  private listen(type: string, handler: EventListener, options?: AddEventListenerOptions) {
    (this.app.canvas as HTMLCanvasElement).addEventListener(type, handler, options);
    this.listeners.push([type, handler, options]);
  }

  update(view: View, levelKey: string) {
    if (this.destroyed) {
      return;
    }
    if (levelKey !== this.levelKey) {
      this.levelKey = levelKey;
      this.fitted = false;
      this.autoFit = true;
    }
    const previousNodes = new Map([...this.nodes].map(([id, entry]) => [id, entry.data]));
    const nodeDelta = diffById(previousNodes, view.nodes, sameNode);
    const moved = new Set<string>();
    for (const id of nodeDelta.removed) {
      this.nodes.get(id)?.graphic.destroy();
      this.nodes.delete(id);
      if (this.selected === id) {
        this.selected = null;
        this.callbacks.onSelect(null);
      }
    }
    for (const node of nodeDelta.added) {
      const graphic = new Graphics(this.contexts[styleOf(node.flags)]);
      this.nodeLayer.addChild(graphic);
      this.nodes.set(node.id, { data: node, graphic });
      this.placeNode(node, graphic);
    }
    for (const node of nodeDelta.changed) {
      const entry = this.nodes.get(node.id)!;
      if (entry.data.x !== node.x || entry.data.y !== node.y) {
        moved.add(node.id);
      }
      if (styleOf(entry.data.flags) !== styleOf(node.flags)) {
        entry.graphic.context = this.contexts[styleOf(node.flags)];
      }
      entry.data = node;
      this.placeNode(node, entry.graphic);
    }

    const previousLinks = new Map([...this.links].map(([id, entry]) => [id, entry.data]));
    const linkDelta = diffById(previousLinks, view.links, sameLink);
    for (const id of linkDelta.removed) {
      this.links.get(id)?.graphic.destroy();
      this.links.delete(id);
    }
    for (const link of linkDelta.added) {
      const graphic = new Graphics();
      this.linkLayer.addChild(graphic);
      this.links.set(link.id, { data: link, graphic });
      this.drawLink(link, graphic);
    }
    for (const link of linkDelta.changed) {
      const entry = this.links.get(link.id)!;
      entry.data = link;
      this.drawLink(link, entry.graphic);
    }
    if (moved.size) {
      for (const entry of this.links.values()) {
        if (moved.has(entry.data.a) || moved.has(entry.data.b)) {
          this.drawLink(entry.data, entry.graphic);
        }
      }
    }
    if (!this.fitted && this.nodes.size) {
      this.fit();
    }
    this.drawRoute();
    this.placeMarkers();
    this.drawLabels();
    this.drawOtherPresences();
    this.requestRender();
  }

  setSelection(id: string | null) {
    this.selected = id;
    this.placeMarkers();
    this.requestRender();
  }

  setPresence(id: string | null) {
    this.presenceNode = id;
    this.placeMarkers();
    this.requestRender();
  }

  setOtherPresences(counts: NodePresenceCounts | null) {
    this.otherPresences = counts;
    this.drawOtherPresences();
    this.requestRender();
  }

  setActivity(counts: NodeActivityCounts | null) {
    this.activity = counts;
    this.drawActivity();
    this.requestRender();
    if (this.activity && Object.keys(this.activity).length > 0) {
      this.startActivityPulse();
    }
  }

  setAgents(agents: readonly SceneAgent[] | null) {
    this.agents = agents;
    this.drawAgents();
    this.drawLabels();
    this.requestRender();
  }

  setOperators(operators: readonly SceneOperator[] | null) {
    this.operators = operators;
    this.drawOperators();
    this.drawLabels();
    this.requestRender();
  }

  private startActivityPulse() {
    this.pulseStart = performance.now();
    if (this.destroyed || this.pulseFrame) {
      return;
    }
    const step = () => {
      this.pulseFrame = 0;
      if (this.destroyed) {
        return;
      }
      const elapsed = performance.now() - this.pulseStart;
      if (elapsed > ACTIVITY_PULSE_MS) {
        this.pulsePhase = 0;
        this.drawActivity();
        this.requestRender();
        return;
      }
      this.pulsePhase = 0.5 + 0.5 * Math.sin(elapsed / 180);
      this.drawActivity();
      this.requestRender();
      this.pulseFrame = requestAnimationFrame(step);
    };
    this.pulseFrame = requestAnimationFrame(step);
  }

  setRoute(route: SceneRoute | null) {
    this.route = route;
    this.drawRoute();
    this.requestRender();
  }

  setFilters(filters: SceneFilters) {
    this.filters = filters;
    for (const entry of this.nodes.values()) {
      entry.graphic.visible = this.nodeVisible(entry.data);
    }
    for (const entry of this.links.values()) {
      entry.graphic.visible = this.linkVisible(entry.data);
    }
    this.drawRoute();
    this.placeMarkers();
    this.drawOtherPresences();
    this.requestRender();
  }

  fit() {
    // The ResizeObserver may not have reported the current layout yet: fit to the element itself.
    this.syncSize();
    const { width, height } = this.app.screen;
    this.view = fitView([...this.nodes.values()].map(entry => entry.data), width, height, this.view);
    // A fit into a not-yet-laid-out element does not count; the next resize fits again.
    this.fitted = this.nodes.size > 0 && width > 1 && height > 1;
    this.autoFit = true;
    this.applyView();
    this.drawRoute();
    this.drawOtherPresences();
  }

  destroy() {
    if (this.destroyed) {
      return;
    }
    this.destroyed = true;
    if (this.frame) {
      cancelAnimationFrame(this.frame);
    }
    if (this.resizeFrame) {
      cancelAnimationFrame(this.resizeFrame);
      this.resizeFrame = 0;
    }
    this.observer?.disconnect();
    const canvas = this.app.canvas as HTMLCanvasElement;
    for (const [type, handler, options] of this.listeners) {
      canvas.removeEventListener(type, handler, options);
    }
    // Graphics destroy their own contexts; the shared node contexts go once, after their users.
    for (const entry of this.nodes.values()) {
      entry.graphic.destroy();
    }
    for (const entry of this.links.values()) {
      entry.graphic.destroy();
    }
    this.nodes.clear();
    this.links.clear();
    this.routeGraphic.destroy();
    this.selection.destroy();
    this.presence.destroy();
    this.otherPresenceGraphic.destroy();
    this.activityGraphic.destroy();
    this.agentGraphic.destroy();
    this.operatorGraphic.destroy();
    this.labelLayer.destroy({ children: true });
    if (this.pulseFrame) {
      cancelAnimationFrame(this.pulseFrame);
      this.pulseFrame = 0;
    }
    for (const context of Object.values(this.contexts)) {
      context.destroy();
    }
    this.world.destroy({ children: true });
    this.app.destroy(true);
  }

  private nodeVisible(node: ViewNode) {
    return this.filters.devices || !(node.flags & FLAG_DEVICE);
  }

  private linkVisible(link: ViewLink) {
    if (link.radio && !this.filters.radio) {
      return false;
    }
    const a = this.nodes.get(link.a)?.data;
    const b = this.nodes.get(link.b)?.data;
    return !!a && !!b && this.nodeVisible(a) && this.nodeVisible(b);
  }

  private placeNode(node: ViewNode, graphic: Graphics) {
    const point = toWorld(node);
    graphic.position.set(point.x, point.y);
    graphic.scale.set(this.nodeScale());
    graphic.visible = this.nodeVisible(node);
  }

  private drawLink(link: ViewLink, graphic: Graphics) {
    const a = this.nodes.get(link.a)?.data;
    const b = this.nodes.get(link.b)?.data;
    graphic.clear();
    if (!a || !b) {
      graphic.visible = false;
      return;
    }
    const from = toWorld(a);
    const to = toWorld(b);
    graphic
      .moveTo(from.x, from.y)
      .lineTo(to.x, to.y)
      .stroke(link.radio
        ? { width: 1, color: COLORS.air, alpha: 0.55 }
        : link.down
          ? { width: 1, color: COLORS.silent, alpha: 0.3 }
          : { width: 1.5, color: COLORS.wire, alpha: 0.9 });
    graphic.visible = this.linkVisible(link);
  }

  private drawRoute() {
    const graphic = this.routeGraphic.clear();
    if (!this.route) {
      return;
    }
    const { broken, moving, nodes, radioLegs } = this.route;
    for (let index = 1; index < nodes.length; index++) {
      const from = this.nodes.get(nodes[index - 1] ?? '');
      const to = this.nodes.get(nodes[index] ?? '');
      if (!from?.graphic.visible || !to?.graphic.visible) {
        continue;
      }
      const a = from.graphic.position;
      const b = to.graphic.position;
      const radio = radioLegs.includes(index);
      if (moving && !radio) {
        graphic.moveTo(a.x, a.y).lineTo(b.x, b.y);
        continue;
      }
      const dx = b.x - a.x;
      const dy = b.y - a.y;
      const dashes = Math.max(1, Math.min(12, Math.round(Math.hypot(dx, dy) * this.view.scale / 12)));
      for (let dash = 0; dash < dashes; dash++) {
        const start = dash / dashes;
        const end = (dash + (radio ? 0.35 : 0.65)) / dashes;
        graphic.moveTo(a.x + dx * start, a.y + dy * start).lineTo(a.x + dx * end, a.y + dy * end);
      }
    }
    graphic.stroke({
      width: (moving || broken ? 3 : 2) / this.view.scale,
      color: broken ? COLORS.routeBreak : moving ? COLORS.presence : COLORS.preview,
    });
  }

  private placeMarkers() {
    this.placeMarker(this.selection, this.selected);
    this.placeMarker(this.presence, this.presenceNode);
  }

  private placeMarker(marker: Graphics, node: string | null) {
    const entry = node ? this.nodes.get(node) : undefined;
    if (!entry || !entry.graphic.visible) {
      marker.visible = false;
      return;
    }
    marker.visible = true;
    marker.position.copyFrom(entry.graphic.position);
    marker.scale.set(this.nodeScale());
  }

  /** Quiet halo where the network just changed: presence moves, agents, conversations. */
  private drawActivity() {
    const graphic = this.activityGraphic.clear();
    const pixel = 1 / this.view.scale;
    for (const [id, count] of Object.entries(this.activity ?? {})) {
      const node = this.nodes.get(id)?.graphic;
      if (!node?.visible || !(count > 0)) {
        continue;
      }
      const radius = (7 + Math.min(4, count) + this.pulsePhase * 2) * pixel;
      graphic
        .circle(node.position.x, node.position.y, radius)
        .fill({ color: COLORS.activity, alpha: 0.12 + this.pulsePhase * 0.12 })
        .stroke({ width: pixel, color: COLORS.activity, alpha: 0.35 + this.pulsePhase * 0.3 });
    }
  }

  /** P13: agents standing on visible nodes: a diamond per entity, coloured by its goal. */
  private drawAgents() {
    const graphic = this.agentGraphic.clear();
    const pixel = 1 / this.view.scale;
    for (const agent of this.agents ?? []) {
      const node = this.nodes.get(agent.node)?.graphic;
      if (!node?.visible) {
        continue;
      }
      const radius = 3 * pixel;
      const offset = 9 * pixel;
      const x = node.position.x - offset;
      const y = node.position.y + offset;
      const color = agent.goal === 'intruder' ? 0xff6868
        : agent.goal === 'saboteur' ? 0xffa94d
          : agent.goal === 'engineer' ? 0x8ce99a
            : COLORS.agent;
      graphic
        .moveTo(x, y - radius)
        .lineTo(x + radius, y)
        .lineTo(x, y + radius)
        .lineTo(x - radius, y)
        .lineTo(x, y - radius)
        .fill(color)
        .stroke({ width: pixel, color: COLORS.background });
    }
  }

  /** P13: a ring with the persona colour marks another operator's presence. */
  private drawOperators() {
    const graphic = this.operatorGraphic.clear();
    const pixel = 1 / this.view.scale;
    for (const operator of this.operators ?? []) {
      const node = this.nodes.get(operator.node)?.graphic;
      if (!node?.visible) {
        continue;
      }
      const radius = 7 * pixel;
      graphic
        .circle(node.position.x, node.position.y, radius)
        .stroke({ width: 1.5 * pixel, color: OPERATOR_COLOURS[operator.colour % OPERATOR_COLOURS.length], alpha: 0.9 });
    }
  }

  /** P13: short labels next to agents and other operators, so names are readable on the map. */
  private drawLabels() {
    const desired = new Map<string, { node: string; text: string; colour: number }>();
    for (const agent of this.agents ?? []) {
      desired.set(`a:${agent.node}:${agent.label}`, {
        node: agent.node,
        text: agent.label.slice(0, 12),
        colour: agent.goal === 'intruder' ? 0xff6868 : COLORS.agent,
      });
    }
    for (const operator of this.operators ?? []) {
      desired.set(`o:${operator.node}:${operator.label}`, {
        node: operator.node,
        text: operator.label.slice(0, 12),
        colour: OPERATOR_COLOURS[operator.colour % OPERATOR_COLOURS.length],
      });
    }
    for (const [key, label] of this.labels) {
      if (!desired.has(key)) {
        label.destroy();
        this.labels.delete(key);
      }
    }
    for (const [key, entry] of desired) {
      const node = this.nodes.get(entry.node)?.graphic;
      let label = this.labels.get(key);
      if (!node?.visible) {
        if (label) {
          label.visible = false;
        }
        continue;
      }
      if (!label) {
        label = new Text({
          text: entry.text,
          style: {
            fontFamily: 'Verdana',
            fontSize: 11,
            fill: entry.colour,
            stroke: { color: 0x101217, width: 2 },
          },
        });
        label.anchor.set(0, 1);
        this.labels.set(key, label);
        this.labelLayer.addChild(label);
      }
      label.visible = true;
      label.position.set(node.position.x + 9, node.position.y - 7);
    }
  }

  private drawOtherPresences() {
    const graphic = this.otherPresenceGraphic.clear();
    const pixel = 1 / this.view.scale;
    const radius = 4 * pixel;
    const offset = 6 * pixel;
    for (const [id, count] of Object.entries(this.otherPresences ?? {})) {
      const node = this.nodes.get(id)?.graphic;
      if (!node?.visible || !(count > 0)) {
        continue;
      }
      const x = node.position.x + offset;
      const y = node.position.y - offset;
      graphic
        .moveTo(x, y - radius)
        .lineTo(x + radius, y)
        .lineTo(x, y + radius)
        .lineTo(x - radius, y)
        .lineTo(x, y - radius)
        .fill(COLORS.otherPresence)
        .stroke({ width: pixel, color: COLORS.background });
    }
  }

  /** Node graphics are drawn at 1 world unit per pixel; this keeps them NODE_PIXELS wide on screen. */
  private nodeScale() {
    return Math.max(TILE * 0.5, NODE_PIXELS / this.view.scale) / (TILE * 0.5);
  }

  private applyView() {
    this.world.position.set(this.view.x, this.view.y);
    this.world.scale.set(this.view.scale);
    const scale = this.nodeScale();
    for (const entry of this.nodes.values()) {
      entry.graphic.scale.set(scale);
    }
    this.placeMarkers();
    this.requestRender();
  }

  /** Matches the renderer to the host element; returns whether the size changed. */
  private syncSize() {
    const width = Math.max(1, this.host.clientWidth);
    const height = Math.max(1, this.host.clientHeight);
    if (width === this.app.screen.width && height === this.app.screen.height) {
      return false;
    }
    this.app.renderer.resize(width, height);
    return true;
  }

  private resize() {
    if (this.destroyed || !this.syncSize()) {
      return;
    }
    if (this.nodes.size && (!this.fitted || this.autoFit)) {
      this.fit();
    }
    this.requestRender();
  }

  private requestRender() {
    if (this.destroyed || this.frame) {
      return;
    }
    this.frame = requestAnimationFrame(() => {
      this.frame = 0;
      if (!this.destroyed) {
        this.app.render();
      }
    });
  }

  private onWheel = (event: WheelEvent) => {
    event.preventDefault();
    this.autoFit = false;
    this.view = zoomAt(this.view, Math.exp(-event.deltaY * 0.0015), event.offsetX, event.offsetY);
    this.applyView();
    this.drawRoute();
    this.drawOtherPresences();
  };

  private onPointerDown = (event: PointerEvent) => {
    (event.target as Element).setPointerCapture?.(event.pointerId);
    this.drag = { x: event.offsetX, y: event.offsetY, travel: 0 };
  };

  private onPointerMove = (event: PointerEvent) => {
    if (!this.drag) {
      return;
    }
    const dx = event.offsetX - this.drag.x;
    const dy = event.offsetY - this.drag.y;
    this.drag = { x: event.offsetX, y: event.offsetY, travel: this.drag.travel + Math.abs(dx) + Math.abs(dy) };
    if (this.drag.travel > CLICK_TRAVEL) {
      this.autoFit = false;
    }
    this.view = { ...this.view, x: this.view.x + dx, y: this.view.y + dy };
    this.applyView();
  };

  private onPointerUp = (event: PointerEvent) => {
    const drag = this.drag;
    this.drag = null;
    if (!drag || drag.travel > CLICK_TRAVEL) {
      return;
    }
    const point = screenToWorld(this.view, event.offsetX, event.offsetY);
    const radius = (NODE_PIXELS * 2) / this.view.scale;
    const visible = [...this.nodes.values()].filter(entry => entry.graphic.visible).map(entry => entry.data);
    this.callbacks.onSelect(nearestNode(visible, point.x, point.y, radius)?.id ?? null);
  };

  private onPointerCancel = () => {
    this.drag = null;
  };

  private onContextLost = (event: Event) => {
    event.preventDefault();
    this.callbacks.onFailure('context_lost');
  };
}

/**
 * Creates the renderer inside `host`. `isCancelled` covers a screen that closes during the
 * asynchronous init: the half-made Application is destroyed and SceneCancelled is thrown.
 */
export const createScene = async (
  host: HTMLElement,
  callbacks: SceneCallbacks,
  isCancelled: () => boolean,
): Promise<TopologyScene> => {
  const app = new Application();
  await app.init({
    width: Math.max(1, host.clientWidth),
    height: Math.max(1, host.clientHeight),
    preference: ['webgl', 'canvas'],
    background: COLORS.background,
    antialias: true,
    autoStart: false,
    autoDensity: true,
    resolution: Math.min(window.devicePixelRatio || 1, 2),
  });
  if (isCancelled()) {
    app.destroy(true);
    throw new SceneCancelled();
  }
  const half = TILE * 0.5;
  const contexts: Record<Style, GraphicsContext> = {
    apc: new GraphicsContext().rect(-half, -half, half * 2, half * 2).fill(COLORS.apc),
    wired: new GraphicsContext().circle(0, 0, half * 0.8).fill(COLORS.wired),
    radio: new GraphicsContext().circle(0, 0, half * 0.8).fill(COLORS.radio),
    node: new GraphicsContext().circle(0, 0, half * 0.6).fill(COLORS.node),
    apcOffline: new GraphicsContext().rect(-half, -half, half * 2, half * 2).fill(COLORS.offline),
    nodeOffline: new GraphicsContext().circle(0, 0, half * 0.8).fill(COLORS.offline),
  };
  const world = new Container();
  const linkLayer = new Container();
  const nodeLayer = new Container();
  const route = new Graphics();
  const selection = new Graphics().circle(0, 0, half * 1.6).stroke({ width: 1.5, color: COLORS.selection });
  selection.visible = false;
  const presence = new Graphics().circle(0, 0, half * 2.2).stroke({ width: 2, color: COLORS.presence });
  presence.visible = false;
  world.addChild(linkLayer, route, nodeLayer, selection, presence);
  app.stage.addChild(world);
  return new PixiTopologyScene(app, host, callbacks, world, linkLayer, nodeLayer, route, selection, presence, contexts);
};
