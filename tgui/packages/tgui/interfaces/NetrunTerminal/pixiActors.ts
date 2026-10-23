import type { Container, Graphics, Text } from 'pixi.js';

import { markerColor, physicalPoint } from './graphRenderer';
import type { GraphOverlay } from './graphRenderer';
import type { GraphScene, PlacedNode } from './graphScene';
import type { NetEdge } from './types';

type Pixi = typeof import('pixi.js');
type Camera = { x: number; y: number; zoom: number };
const color = (value: string | undefined, fallback: number) =>
  value && /^#[0-9a-f]{6}$/i.test(value) ? Number.parseInt(value.slice(1), 16) : fallback;

/**
 * All live game decorations are drawn in Pixi batches. No SVG/DOM actor
 * layer is active in GPU mode. Static geometry is managed independently.
 */
export class PixiActors {
  readonly world: Container;
  private readonly paths: Graphics;
  private readonly selectedLinks: Graphics;
  private readonly routes: Graphics[];
  private readonly bodies: Graphics;
  private readonly marks: Graphics;
  private readonly events: Graphics;
  private readonly badgeLayer: Container;
  private readonly badges: Text[] = [];
  private scene: GraphScene | null = null;
  private overlay: GraphOverlay | null = null;
  private dynamicEdges: NetEdge[] = [];
  private adjacency = new Map<string, Set<string>>();
  private cameraZoom = 1;
  private readonly TextClass: Pixi['Text'];

  constructor(pixi: Pixi) {
    const { Container: Group, Graphics: Shape, Text: PixiText } = pixi;
    this.TextClass = PixiText;
    this.world = new Group();
    this.paths = new Shape();
    this.selectedLinks = new Shape();
    this.routes = Array.from({ length: 3 }, () => new Shape());
    this.bodies = new Shape();
    this.marks = new Shape();
    this.events = new Shape();
    this.badgeLayer = new Group();
    this.world.addChild(this.paths, this.selectedLinks, ...this.routes,
      this.bodies, this.marks, this.events, this.badgeLayer);
  }

  update(scene: GraphScene, overlay: GraphOverlay, dynamicEdges: NetEdge[],
    adjacency: Map<string, Set<string>>) {
    const previous = this.overlay;
    if (this.scene === scene && previous
      && previous.selected === overlay.selected && previous.jacked === overlay.jacked
      && previous.entityHost === overlay.entityHost && previous.gateways === overlay.gateways
      && previous.selectedRoute === overlay.selectedRoute
      && previous.waypointRoute === overlay.waypointRoute && previous.pingRoute === overlay.pingRoute
      && previous.events === overlay.events
      && this.dynamicEdges === dynamicEdges && this.adjacency === adjacency) { return false; }
    this.scene = scene; this.overlay = overlay;
    this.dynamicEdges = dynamicEdges; this.adjacency = adjacency;
    this.paint();
    return true;
  }

  setZoom(zoom: number) {
    if (this.cameraZoom === zoom) { return; }
    const oldDetailed = this.cameraZoom >= .6, nextDetailed = zoom >= .6;
    this.cameraZoom = zoom;
    if (oldDetailed !== nextDetailed) { this.paint(); }
  }

  private paint() {
    const scene = this.scene, overlay = this.overlay;
    for (const graphic of [this.paths, this.selectedLinks, ...this.routes,
      this.bodies, this.marks, this.events]) { graphic.clear(); }
    if (!scene || !overlay) { return; }
    const detailed = this.cameraZoom >= .6;
    const specs: { text: string; x: number; y: number }[] = [];
    const addBadge = (text: string, x: number, y: number) => {
      if (specs.length < 48) { specs.push({ text, x, y }); }
    };
    for (const edge of this.dynamicEdges.slice(0, 5000)) {
      const a = scene.byAddress.get(edge.from), b = scene.byAddress.get(edge.to);
      if (!a || !b) { continue; }
      const from = physicalPoint(a), to = physicalPoint(b);
      this.paths.moveTo(from.px, from.py).lineTo(to.px, to.py);
    }
    // Anchor connectors for physically stacked and mobile devices.
    for (const node of scene.nodes) {
      if (!node.dynamic) { continue; }
      const from = physicalPoint(node);
      if (from.px !== node.px || from.py !== node.py) {
        this.paths.moveTo(from.px, from.py).lineTo(node.px, node.py);
      }
    }
    this.paths.stroke({ color: 0x4c8fa7, alpha: .8, width: 1.5 });
    const selectedNode = overlay.selected && scene.byAddress.get(overlay.selected);
    if (selectedNode && detailed) {
      const neighbors = this.adjacency.get(selectedNode.address) || new Set<string>();
      for (const address of neighbors) {
        const target = scene.byAddress.get(address);
        if (!target) { continue; }
        const a = physicalPoint(selectedNode), b = physicalPoint(target);
        this.selectedLinks.moveTo(a.px, a.py).lineTo(b.px, b.py);
      }
      const dense = neighbors.size > 24;
      this.selectedLinks.stroke({ color: 0x9ad0e0, width: dense ? 1 : 2.5, alpha: dense ? .22 : 1 });
    }
    const drawRoute = (addresses: string[], index: number, tint: number) => {
      const graphic = this.routes[index];
      for (let i = 1; i < Math.min(257, addresses.length); i++) {
        const a = scene.byAddress.get(addresses[i - 1]), b = scene.byAddress.get(addresses[i]);
        if (!a || !b || !this.adjacency.get(a.address)?.has(b.address)) { continue; }
        const from = physicalPoint(a), to = physicalPoint(b);
        graphic.moveTo(from.px, from.py).lineTo(to.px, to.py);
      }
      graphic.stroke({ color: tint, width: 3.5, alpha: .95 });
    };
    drawRoute(overlay.selectedRoute, 0, 0x50e8c0);
    drawRoute(overlay.waypointRoute, 1, 0xe879b8);
    drawRoute(overlay.pingRoute, 2, 0xffc56b);

    for (const node of scene.nodes) {
      const selected = node.address === overlay.selected;
      const hosted = node.address === overlay.entityHost;
      const jacked = node.address === overlay.jacked;
      if (!node.dynamic && !selected && !hosted && !jacked
        && !node.active && !node.ice && !node.entities) { continue; }
      const { px, py } = node;
      if (node.dynamic) {
        this.drawBody(node, color(markerColor(node), 0x678698),
          color(overlay.gateways.get(node.network)?.color, 0x82a9ba));
      }
      if (selected || hosted || jacked) {
        this.marks.circle(px, py, 20).stroke({
          color: selected ? 0xeafff5 : hosted ? 0xf8a3e6 : 0x65b4d5, width: 2,
        });
      }
      if (node.ice) {
        this.marks.circle(px, py, 22).stroke({ color: 0xef6b7c, width: 1.5, alpha: .85 });
        this.marks.circle(px - 15, py - 15, detailed ? 7 : 3.5).fill({ color: 0xff6470 });
        if (detailed) { addBadge(node.ice > 9 ? '+' : String(node.ice), px - 19, py - 21); }
      } else if (node.active) {
        this.marks.circle(px, py, 18).stroke({ color: 0xffc26b, width: 1.5, alpha: .85 });
      }
      if (node.entities) {
        this.marks.roundRect(px + 10, py - 20, detailed ? 12 : 6, detailed ? 12 : 6, 2)
          .fill({ color: 0xf19bdc });
        if (detailed) { addBadge(node.entities > 9 ? '+' : String(node.entities), px + 13, py - 19); }
      }
    }
    for (const event of overlay.events.slice(0, 128)) {
      const node = (event.to && scene.byAddress.get(event.to))
        || (event.from && scene.byAddress.get(event.from));
      if (!node || event.age >= 4) { continue; }
      this.events.circle(node.px, node.py, 23).stroke({
        color: event.kind === 'trace' ? 0xf56670 : 0xffc26b,
        width: 1.5, alpha: Math.max(.1, 1 - event.age / 4),
      });
    }
    for (let i = 0; i < specs.length; i++) {
      let label = this.badges[i];
      if (!label) {
        label = new this.TextClass({
          text: '', style: { fontFamily: 'monospace', fontSize: 9, fill: 0x2a0f24 },
        });
        this.badges.push(label);
        this.badgeLayer.addChild(label);
      }
      label.text = specs[i].text;
      label.position.set(specs[i].x, specs[i].y);
      label.visible = true;
    }
    for (let i = specs.length; i < this.badges.length; i++) { this.badges[i].visible = false; }
  }

  private drawBody(node: PlacedNode, fill: number, border: number) {
    const graphic = this.bodies;
    const { px, py } = node;
    if (node.type === 'apc') {
      graphic.rect(px - 11, py - 11, 22, 22);
    } else if (node.type === 'gateway' || node.type === 'relay') {
      for (let i = 0; i < 6; i++) {
        const a = i * Math.PI / 3;
        if (i === 0) { graphic.moveTo(px + Math.cos(a) * 14, py + Math.sin(a) * 14); }
        else { graphic.lineTo(px + Math.cos(a) * 14, py + Math.sin(a) * 14); }
      }
      graphic.closePath();
    } else if (node.type === 'server' || node.type === 'terminal') {
      graphic.moveTo(px, py - 12).lineTo(px + 12, py).lineTo(px, py + 12)
        .lineTo(px - 12, py).closePath();
    } else {
      graphic.circle(px, py, 8);
    }
    graphic.fill({ color: fill }).stroke({ color: border, width: 1.5 });
  }
}
