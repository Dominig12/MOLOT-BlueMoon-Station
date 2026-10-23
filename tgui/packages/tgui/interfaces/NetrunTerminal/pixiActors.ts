import type { Container, Graphics, Text } from 'pixi.js';

import { GRAPH_TILE } from './graphLayout';
import { boxesIntersect, GraphBox, GraphOverlay, markerColor, markerScale, physicalPoint, segmentBox } from './graphPresentation';
import type { GraphScene, PlacedNode } from './graphScene';
import type { GraphPoint } from './mapLayout';
import { destroyDisplay, edgeColor, markerPath, pixiColor, PixiLibrary, segmentPath } from './pixiPrimitives';
import type { NetEdge } from './types';

type Actor = { group: Container; body: Graphics; marks: Graphics; labels: Text[]; node: PlacedNode;
  signature: string; px: number; py: number; fromX: number; fromY: number; movedAt: number; appearedAt: number };
type Link = { graphic: Graphics; signature: string; bounds: GraphBox };
type Segment = { from: GraphPoint; to: GraphPoint; length: number };
type Route = { graphic: Graphics; signature: string; segments: Segment[]; until: number; began: number; tint: number };
type Traffic = { born: number; point: GraphPoint; trace: boolean; segments: Segment[] };
type Pulse = { born: number; point: GraphPoint; tint: number };
const NO_BOX: GraphBox = { left: -Infinity, right: Infinity, top: -Infinity, bottom: Infinity };
const sameOverlayData = (a: GraphOverlay | null, b: GraphOverlay) => a
  && a.gateways === b.gateways && a.entityHost === b.entityHost && a.jacked === b.jacked
  && a.selectedRoute === b.selectedRoute && a.waypointRoute === b.waypointRoute
  && a.pingRoute === b.pingRoute && a.events === b.events;
const sameLocalState = (a: GraphOverlay, b: GraphOverlay) => a.selected === b.selected
  && a.hovered === b.hovered && a.selectionPending === b.selectionPending;
const pointOn = (segments: Segment[], progress: number) => {
  let remaining = segments.reduce((sum, segment) => sum + segment.length, 0) * progress;
  for (const segment of segments) {
    if (remaining <= segment.length) {
      const t = segment.length ? remaining / segment.length : 0;
      return { px: segment.from.px + (segment.to.px - segment.from.px) * t, py: segment.from.py + (segment.to.py - segment.from.py) * t };
    }
    remaining -= segment.length;
  }
  return segments[segments.length - 1]?.to;
};

/** Keyed live objects: moving one endpoint never retessellates the stationary map. */
export class PixiActors {
  readonly world: Container;
  positionsChanged = false;
  private readonly linkLayer: Container;
  private readonly nodeLayer: Container;
  private readonly selectedLinks: Graphics;
  private readonly effects: Graphics;
  private readonly routes: Route[];
  private readonly nodes = new Map<string, Actor>();
  private readonly links = new Map<string, Link>();
  private scene: GraphScene | null = null;
  private overlay: GraphOverlay | null = null;
  private dynamicEdges: NetEdge[] | null = null;
  private adjacency = new Map<string, Set<string>>();
  private selectedSignature = '';
  private traffic: Traffic[] = [];
  private pulses: Pulse[] = [];
  private zoom = 1;
  private scale = 1;
  private detailed = true;
  private bounds = NO_BOX;
  private reducedMotion = false;
  private moving: PlacedNode[] = [];
  private blocked = new Set<string>();

  constructor(private readonly pixi: PixiLibrary) {
    this.world = new pixi.Container(); this.world.label = 'netrun-live';
    this.linkLayer = new pixi.Container(); this.linkLayer.label = 'moving-cables';
    this.nodeLayer = new pixi.Container(); this.nodeLayer.label = 'processes-and-devices';
    this.selectedLinks = new pixi.Graphics();
    this.effects = new pixi.Graphics(); this.effects.label = 'traffic-and-ping';
    this.routes = [0x50e8c0, 0xe879b8, 0xffc56b].map((tint) => ({ graphic: new pixi.Graphics(), signature: '', segments: [], began: 0, until: 0, tint }));
    this.world.addChild(this.linkLayer, this.selectedLinks, ...this.routes.map((route) => route.graphic), this.nodeLayer, this.effects);
  }

  update(scene: GraphScene, overlay: GraphOverlay, dynamicEdges: NetEdge[], adjacency: Map<string, Set<string>>, now = performance.now()) {
    const before = this.overlay;
    const localOnly = this.scene === scene && this.dynamicEdges === dynamicEdges && this.adjacency === adjacency && sameOverlayData(before, overlay);
    if (localOnly && sameLocalState(before, overlay)) { return false; }
    const affected = localOnly ? [...new Set([before.selected, before.hovered, overlay.selected, overlay.hovered])]
      .map((address) => scene.byAddress.get(address)).filter(Boolean) : scene.nodes;
    this.scene = scene; this.overlay = overlay; this.dynamicEdges = dynamicEdges; this.adjacency = adjacency;
    // Short, event-triggered focus animation: never leave the GPU ticker running.
    if (before?.selected !== overlay.selected && overlay.selected && !this.reducedMotion) {
      const node = scene.byAddress.get(overlay.selected);
      if (node) { this.pulses.push({ born: now, point: node, tint: 0x6fe9dc }); }
    }
    if (!localOnly) {
      this.moving = scene.nodes.filter((node) => node.dynamic);
      this.blocked = new Set([...scene.edges, ...dynamicEdges].filter((edge) => edge.online === false)
        .map((edge) => [edge.from, edge.to].sort().join('|')));
    }
    const alive = new Set<string>();
    for (const node of affected) {
      if (!node.dynamic && !node.entities && !node.ice && !node.active && node.address !== overlay.selected
        && node.address !== overlay.hovered && node.address !== overlay.entityHost && node.address !== overlay.jacked) {
        const removed = this.nodes.get(node.address);
        if (removed && localOnly) { destroyDisplay(removed.group); this.nodes.delete(node.address); }
        continue;
      }
      alive.add(node.address);
      let actor = this.nodes.get(node.address);
      if (actor && node.ice && node.ice > (actor.node.ice || 0) && !this.reducedMotion) {
        this.pulses.push({ born: now, point: node, tint: 0xf37b93 });
      }
      if (!actor) {
        const group = new this.pixi.Container(); group.label = `device:${node.address}`;
        const body = new this.pixi.Graphics(), marks = new this.pixi.Graphics(); group.addChild(body, marks);
        actor = { group, body, marks, labels: [], node, signature: '', px: node.px, py: node.py,
          fromX: node.px, fromY: node.py, movedAt: -Infinity, appearedAt: now };
        this.nodes.set(node.address, actor); this.nodeLayer.addChild(group); group.position.set(node.px, node.py);
      } else if (node.px !== actor.node.px || node.py !== actor.node.py) {
        // Real teleports snap; normal carried-device steps ease briefly.
        const smooth = !this.reducedMotion && node.dynamic && Math.hypot(node.px - actor.px, node.py - actor.py) <= GRAPH_TILE * 4;
        actor.fromX = actor.px; actor.fromY = actor.py; actor.movedAt = smooth ? now : -Infinity;
        if (!smooth) { actor.px = node.px; actor.py = node.py; actor.group.position.set(node.px, node.py); }
      }
      actor.node = node; this.paintActor(actor);
    }
    if (!localOnly) {
      for (const [address, actor] of this.nodes) { if (!alive.has(address)) { destroyDisplay(actor.group); this.nodes.delete(address); } }
    }
    const linkKeys = new Set<string>();
    for (const edge of dynamicEdges) {
      const a = scene.byAddress.get(edge.from), b = scene.byAddress.get(edge.to);
      if (!a || !b) { continue; }
      linkKeys.add(edge.id);
      const from = physicalPoint(a), to = physicalPoint(b), signature = `${from.px},${from.py}:${to.px},${to.py}:${edge.kind}:${edge.online}`;
      let retained = this.links.get(edge.id);
      if (!retained) {
        retained = { graphic: new this.pixi.Graphics(), signature: '', bounds: segmentBox(from, to) };
        retained.graphic.label = `edge:${edge.id}`; this.links.set(edge.id, retained); this.linkLayer.addChild(retained.graphic);
      }
      retained.bounds = segmentBox(from, to);
      if (retained.signature !== signature) {
        retained.signature = signature;
        retained.graphic.clear().moveTo(from.px, from.py).lineTo(to.px, to.py)
          .stroke({ color: edgeColor(edge.kind, edge.online !== false), width: 1.6, alpha: edge.online === false ? .4 : .85 });
      }
    }
    for (const [id, link] of this.links) { if (!linkKeys.has(id)) { destroyDisplay(link.graphic); this.links.delete(id); } }
    this.paintPaths();
    this.paintRoute(overlay.selectedRoute, this.routes[0], now); this.paintRoute(overlay.waypointRoute, this.routes[1], now);
    this.paintRoute(overlay.pingRoute, this.routes[2], now, true);
    if (!localOnly) { this.traffic = overlay.events.filter((event) => event.age < 4).flatMap((event) => {
      const point = scene.byAddress.get(event.to) || scene.byAddress.get(event.from);
      return point ? [{ born: now - Math.max(0, event.age) * 1000, point, trace: event.kind === 'trace', segments: this.eventPath(event.from, event.to) }] : [];
    }); }
    if (this.pulses.length > 24) { this.pulses.splice(0, this.pulses.length - 24); }
    this.setViewport(this.bounds, this.zoom); return true;
  }

  private paintActor(actor: Actor) {
    const node = actor.node, overlay = this.overlay!;
    const selected = node.address === overlay.selected, hosted = node.address === overlay.entityHost;
    const jacked = node.address === overlay.jacked, hovered = node.address === overlay.hovered;
    const fill = pixiColor(markerColor(node), 0x678698), border = pixiColor(overlay.gateways.get(node.network)?.color, 0x82a9ba);
    const signature = `${node.type}:${!!node.dynamic}:${fill}:${border}:${node.entities}:${node.ice}:${node.active}:${selected}:${overlay.selectionPending}:${hosted}:${jacked}:${hovered}:${this.scale}:${this.detailed}`;
    if (actor.signature === signature) { return; }
    actor.signature = signature; actor.body.clear(); actor.marks.clear();
    // No LOD enlargement of ordinary device bodies. This scale is reserved
    // for LAN/ICE/entity contours (never the underlying node).
    if (node.dynamic) { markerPath(actor.body, node.type, 0, 0, 1).fill({ color: fill }).stroke({ color: border, width: 1.5 }); }
    const marks = actor.marks, scale = node.ice || node.entities
      || node.type === 'gateway' || node.type === 'relay' ? this.scale : 1;
    if (node.dynamic && (node.type === 'gateway' || node.type === 'relay')) {
      marks.circle(0, 0, 19 * scale)
        .stroke({ color: border, width: Math.min(3, scale * 1.3), alpha: .64 });
    }
    if (selected || hosted || jacked || hovered) {
      marks.circle(0, 0, hovered && !selected ? 18 : 21).stroke({ color: selected ? overlay.selectionPending ? 0xffd18a : 0xeafff5 : hosted ? 0xf8a3e6 : jacked ? 0x65b4d5 : 0x8ed1ea, width: selected ? 2 : 1.3, alpha: .95 });
      if (selected) { marks.circle(0, 0, 25).stroke({ color: 0x70e6cd, width: 1, alpha: .25 }); }
    }
    if (node.ice) {
      marks.circle(0, 0, 23 * scale).stroke({ color: 0xef6b7c, width: 1.5 * scale, alpha: .8 });
      marks.circle(-16 * scale, -16 * scale, (this.detailed ? 8 : 4) * scale).fill({ color: 0xff6470 });
      marks.circle(0, 0, 28 * scale).stroke({ color: 0xff6470, width: Math.min(2.5, 1.1 * scale), alpha: .28 });
    } else if (node.active) { marks.circle(0, 0, 18 * scale).stroke({ color: 0xffc26b, width: 1.5 * scale, alpha: .8 }); }
    if (node.entities) { marks.roundRect(10 * scale, -23 * scale, (this.detailed ? 16 : 7) * scale, (this.detailed ? 13 : 7) * scale, 2 * scale).fill({ color: 0xf19bdc }); }
    const badges = this.detailed ? [node.ice ? { value: String(node.ice), x: -16 * scale, y: -16 * scale, color: 0x2d1017 } : null,
      node.entities ? { value: String(node.entities), x: 18 * scale, y: -16 * scale, color: 0x2d1026 } : null].filter(Boolean) : [];
    for (let i = 0; i < badges.length; i++) {
      const badge = badges[i]; let label = actor.labels[i];
      if (!label) {
        label = new this.pixi.Text({ text: '', style: { fontFamily: 'monospace', fontSize: 9, fill: badge.color } });
        label.anchor.set(.5); actor.group.addChild(label); actor.labels.push(label);
      }
      label.text = badge.value; label.position.set(badge.x, badge.y); label.scale.set(1 / this.zoom); label.visible = true;
    }
    for (let i = badges.length; i < actor.labels.length; i++) { actor.labels[i].visible = false; }
  }

  private segments(addresses: string[]): Segment[] {
    const result: Segment[] = [];
    for (let i = 1; i < addresses.length; i++) {
      const a = this.scene!.byAddress.get(addresses[i - 1]), b = this.scene!.byAddress.get(addresses[i]);
      if (!a || !b || !a.online || !b.online || !this.adjacency.get(a.address)?.has(b.address)
        || this.blocked.has([a.address, b.address].sort().join('|'))) { continue; }
      const from = physicalPoint(a), to = physicalPoint(b);
      result.push({ from, to, length: Math.hypot(to.px - from.px, to.py - from.py) });
    }
    return result;
  }

  private paintPaths() {
    const selected = this.overlay!.selected && this.scene!.byAddress.get(this.overlay!.selected);
    const edges = selected ? [...(this.adjacency.get(selected.address) || [])].flatMap((address) => {
      const target = this.scene!.byAddress.get(address); return target ? [{ from: physicalPoint(selected), to: physicalPoint(target) }] : [];
    }) : [];
    const anchors = this.moving.flatMap((node) => {
      const point = physicalPoint(node); return point.px === node.px && point.py === node.py ? [] : [{ from: point, to: node }];
    });
    const signature = `${this.detailed}:${edges.length}:` + [...edges, ...anchors].map(({ from, to }) => `${from.px},${from.py}:${to.px},${to.py}`).join('|');
    if (signature === this.selectedSignature) { return; }
    this.selectedSignature = signature; this.selectedLinks.clear();
    if (this.detailed) {
      for (const { from, to } of edges) { segmentPath(this.selectedLinks, from, to); }
      this.selectedLinks.stroke({ color: 0x9ad0e0, width: edges.length > 24 ? 1 : 2.5, alpha: edges.length > 24 ? .22 : .8 });
    }
    for (const { from, to } of anchors) { segmentPath(this.selectedLinks, from, to); }
    if (anchors.length) { this.selectedLinks.stroke({ color: 0x75a3b4, width: 1.2, alpha: .5 }); }
  }

  private paintRoute(addresses: string[], route: Route, now: number, ping = false) {
    const segments = this.segments(addresses), path = segments.map(({ from, to }) => `${from.px},${from.py}:${to.px},${to.py}`).join('|');
    const signature = path;
    if (route.signature === signature) { return; }
    const changedPath = route.signature !== path;
    route.signature = signature; route.segments = segments; route.graphic.clear();
    // Muted continuous path beneath bright dashes improves route legibility
    // at fractional zoom without shaders or multiple display objects.
    for (const segment of segments) { segmentPath(route.graphic, segment.from, segment.to); }
    if (segments.length) { route.graphic.stroke({ color: route.tint, width: 4, alpha: .18 }); }
    for (const segment of segments) { segmentPath(route.graphic, segment.from, segment.to, ping ? 5 : 10, 6); }
    if (segments.length) { route.graphic.stroke({ color: route.tint, width: 2.5, alpha: .85 }); }
    if (ping && changedPath && segments.length) { route.began = now; route.until = now + 1800; }
  }

  private eventPath(from: string, to: string): Segment[] {
    if (!from || !to || from === to || !this.scene!.byAddress.has(from) || !this.scene!.byAddress.has(to)) { return []; }
    const previous = new Map<string, string | null>([[from, null]]), queue = [from];
    for (let i = 0; i < queue.length && !previous.has(to); i++) {
      for (const neighbor of this.adjacency.get(queue[i]) || []) {
        if (!previous.has(neighbor) && this.scene!.byAddress.get(neighbor)?.online
          && !this.blocked.has([queue[i], neighbor].sort().join('|'))) { previous.set(neighbor, queue[i]); queue.push(neighbor); }
      }
    }
    if (!previous.has(to)) { return []; }
    const path = [to]; for (let cursor = previous.get(to); cursor; cursor = previous.get(cursor)) { path.push(cursor); }
    return this.segments(path.reverse());
  }

  setViewport(bounds: GraphBox, zoom: number) {
    const nextScale = markerScale(zoom), detailed = zoom >= .6;
    const geometryChanged = this.scale !== nextScale || this.detailed !== detailed;
    const zoomChanged = this.zoom !== zoom;
    this.bounds = bounds; this.zoom = zoom; this.scale = nextScale; this.detailed = detailed;
    for (const actor of this.nodes.values()) {
      if (geometryChanged && this.overlay) { this.paintActor(actor); }
      actor.group.visible = actor.px >= bounds.left - 32 * nextScale && actor.px <= bounds.right + 32 * nextScale && actor.py >= bounds.top - 32 * nextScale && actor.py <= bounds.bottom + 32 * nextScale;
      if (zoomChanged) { for (const label of actor.labels) { label.scale.set(1 / zoom); } }
    }
    for (const link of this.links.values()) { link.graphic.visible = boxesIntersect(link.bounds, bounds); }
    if (geometryChanged && this.overlay) {
      this.paintPaths(); this.paintRoute(this.overlay.selectedRoute, this.routes[0], performance.now());
      this.paintRoute(this.overlay.waypointRoute, this.routes[1], performance.now()); this.paintRoute(this.overlay.pingRoute, this.routes[2], performance.now(), true);
    }
  }

  setReducedMotion(reduced: boolean) { this.reducedMotion = reduced; }

  /** Only a finite effect/transition can request the next frame. Quiet maps do not tick. */
  animate(now: number) {
    let animating = false;
    this.positionsChanged = false;
    for (const actor of this.nodes.values()) {
      const t = this.reducedMotion ? 1 : Math.min(1, Math.max(0, (now - actor.movedAt) / 180)), eased = 1 - (1 - t) ** 3;
      const px = actor.fromX + (actor.node.px - actor.fromX) * eased, py = actor.fromY + (actor.node.py - actor.fromY) * eased;
      if (px !== actor.px || py !== actor.py) { this.positionsChanged = true; }
      actor.px = px; actor.py = py;
      actor.group.position.set(actor.px, actor.py);
      const opacity = this.reducedMotion ? 1 : Math.min(1, (now - actor.appearedAt) / 150);
      actor.group.alpha = Math.max(0, opacity); if (t < 1 || opacity < 1) { animating = true; }
    }
    if (this.positionsChanged) {
      for (const edge of this.dynamicEdges || []) {
        const a = this.scene!.byAddress.get(edge.from), b = this.scene!.byAddress.get(edge.to), retained = this.links.get(edge.id);
        if (!a || !b || !retained) { continue; }
        const from = physicalPoint(this.pointFor(a)), to = physicalPoint(this.pointFor(b));
        const signature = `${from.px},${from.py}:${to.px},${to.py}:${edge.kind}:${edge.online}`;
        if (retained.signature === signature) { continue; }
        retained.signature = signature; retained.bounds = segmentBox(from, to);
        retained.graphic.clear().moveTo(from.px, from.py).lineTo(to.px, to.py)
          .stroke({ color: edgeColor(edge.kind, edge.online !== false), width: 1.6, alpha: edge.online === false ? .4 : .85 });
      }
    }
    this.effects.clear();
    this.pulses = this.pulses.filter((pulse) => now - pulse.born < 700);
    for (const pulse of this.pulses) {
      const progress = Math.max(0, (now - pulse.born) / 700);
      this.effects.circle(pulse.point.px, pulse.point.py, 19 + progress * 21)
        .stroke({ color: pulse.tint, width: 2.5 - 1.5 * progress, alpha: .8 * (1 - progress) });
      animating = true;
    }
    for (const event of this.traffic) {
      const age = Math.max(0, (now - event.born) / 1000); if (age >= 4) { continue; }
      const tint = event.trace ? 0xf56670 : 0xffc26b;
      if (this.reducedMotion) { this.effects.circle(event.point.px, event.point.py, 24).stroke({ color: tint, width: 1.5, alpha: .65 }); continue; }
      const phase = (age % 1.2) / 1.2;
      this.effects.circle(event.point.px, event.point.py, (20 + phase * 15)).stroke({ color: tint, width: 1.5, alpha: (1 - phase) * (1 - age / 4) });
      const packet = pointOn(event.segments, age % 1); if (packet) { this.effects.circle(packet.px, packet.py, 3).fill({ color: tint, alpha: .9 }); }
      animating = true;
    }
    const ping = this.routes[2];
    if (!this.reducedMotion && now < ping.until && ping.segments.length) {
      const point = pointOn(ping.segments, ((now - ping.began) % 900) / 900);
      if (point) { this.effects.circle(point.px, point.py, 5).fill({ color: ping.tint, alpha: .95 }); } animating = true;
    }
    return animating;
  }

  pointFor(node: PlacedNode): PlacedNode {
    const actor = this.nodes.get(node.address);
    return actor && (actor.px !== node.px || actor.py !== node.py) ? { ...node, px: actor.px, py: actor.py,
      anchorX: (node.anchorX ?? node.px) + actor.px - node.px, anchorY: (node.anchorY ?? node.py) + actor.py - node.py } : node;
  }
  hit(point: GraphPoint, zoom: number): PlacedNode | null {
    let best: PlacedNode | null = null, distance = (16 / zoom) ** 2;
    for (const actor of this.nodes.values()) {
      const next = (actor.px - point.px) ** 2 + (actor.py - point.py) ** 2;
      if (next < distance || (next === distance && (!best || actor.node.address < best.address))) {
        distance = next; best = this.pointFor(actor.node);
      }
    }
    return best;
  }
  destroy() { this.nodes.clear(); this.links.clear(); this.traffic = []; this.pulses = []; this.scene = null; this.overlay = null; destroyDisplay(this.world); }
}
