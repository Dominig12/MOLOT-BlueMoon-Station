import { BooleanLike } from 'common/react';

/** What one observer may see of one digital host. Names arrive only once the identity is established. */
export type HostView = {
  host: number;
  name: string;
  node: number;
  hostClass: string;
  level: string;
  confidence: number;
  ageMs: number;
  stale: BooleanLike;
  available: BooleanLike;
  bufferCu: number;
  effects: number;
  identified: BooleanLike;
};

/** One declared action: cost, cooldown and documentation come from the same descriptor the server uses. */
export type ActionView = {
  id: string;
  kind: string;
  category: string;
  capability: string;
  computeCost: number;
  memoryCost: number;
  cooldownMs: number;
  rangeHops: number;
  displayName: string;
  documentation: string;
};

/** One operation of this observer, newest first. */
export type OperationView = {
  operation: number;
  status: string;
  kind: string;
  category: string;
  reason: string | null;
  result: string | null;
};

export type LinkView = { a: number; b: number; cost: number };

/** A running or finished program of this observer. It runs on the server, not in the window. */
export type ProgramView = {
  process: number;
  definition: string;
  state: string;
  instructions: number;
  runs: number;
  fault: string | null;
  lastAction: string | null;
  lastOutcome: string | null;
};

/** The bounded client refresh. Everything here was filtered on the server before it was sent. */
export type Panel = {
  now: number;
  ticks: number;
  principal: number;
  hosts: HostView[];
  links: LinkView[];
  actions: ActionView[];
  operations: OperationView[];
  programs: ProgramView[];
  knowledge: { known: number; stale: number; total: number };
};

export type Data = { panel: Panel | null; error: string | null; notice: string | null };

export type TabKey = 'network' | 'hosts' | 'programs' | 'events';

export const TABS: { key: TabKey; label: string; icon: string }[] = [
  { key: 'network', label: 'Сеть', icon: 'diagram-project' },
  { key: 'hosts', label: 'Хосты', icon: 'server' },
  { key: 'programs', label: 'Программы', icon: 'code' },
  { key: 'events', label: 'События', icon: 'list' },
];

export type NodeShape = 'circle' | 'square' | 'diamond' | 'hexagon';

export type MapNode = HostView & {
  x: number;
  y: number;
  label: string;
  shape: NodeShape;
};

const SHAPES: Record<string, NodeShape> = {
  accesspoint: 'square',
  relay: 'diamond',
  server: 'hexagon',
  cyberdeck: 'circle',
  terminal: 'circle',
  implant: 'circle',
  external: 'diamond',
  virtual: 'hexagon',
};

/** Shape carries the classification so it survives a monochrome screen; colour is never the only signal. */
export function shapeOf(hostClass: string): NodeShape {
  return SHAPES[String(hostClass || '').toLowerCase()] ?? 'circle';
}

/** A host is named only when its identity was established; before that the class is all an observer has. */
export function labelOf(host: HostView): string {
  return host.identified && host.name ? host.name : String(host.hostClass || 'host');
}

/**
 * Places hosts on a stable grid. Sorting by identifier keeps every existing node in place when another one
 * appears or ages out, so the map does not jump between refreshes.
 */
export function layoutHosts(
  hosts: HostView[],
  columns = 6,
  spacingX = 96,
  spacingY = 84,
  margin = 32,
): MapNode[] {
  const ordered = [...hosts].sort((a, b) => a.host - b.host);
  return ordered.map((host, index) => ({
    ...host,
    x: margin + (index % Math.max(1, columns)) * spacingX,
    y: margin + Math.floor(index / Math.max(1, columns)) * spacingY,
    label: labelOf(host),
    shape: shapeOf(host.hostClass),
  }));
}

/** Width and height of the drawing area for a laid out map, with a margin so labels are not clipped. */
export function mapExtent(nodes: MapNode[], margin = 40): { width: number; height: number } {
  if (nodes.length === 0) {
    return { width: 320, height: 200 };
  }
  let width = 0;
  let height = 0;
  for (const node of nodes) {
    width = Math.max(width, node.x);
    height = Math.max(height, node.y);
  }
  return { width: width + margin * 2, height: height + margin * 2 };
}

/** Keeps only hosts whose knowledge is still fresh, for the "hide outdated" switch. */
export function visibleHosts(hosts: HostView[], hideStale: boolean): HostView[] {
  return hideStale ? hosts.filter(host => !host.stale) : hosts;
}

/** Edges whose both ends are visible. A server never sends an edge to a host it did not reveal. */
export function visibleLinks(links: LinkView[], visible: HostView[]): LinkView[] {
  const shown = new Set(visible.map(host => host.host));
  return links.filter(link => shown.has(link.a) && shown.has(link.b));
}

export function formatAge(milliseconds: number): string {
  const seconds = Math.max(0, Math.round(milliseconds / 1000));
  if (seconds < 60) {
    return `${seconds} с`;
  }
  const minutes = Math.floor(seconds / 60);
  return `${minutes} мин`;
}

export function formatCooldown(milliseconds: number): string {
  return milliseconds > 0 ? `${(milliseconds / 1000).toFixed(1)} с` : '—';
}

/** Footer numbers for one refresh. Only real values: nothing is invented for the HUD. */
export function summarise(panel: Panel | null) {
  if (!panel) {
    return { hosts: '—', stale: '—', actions: '—', operations: '—' };
  }
  return {
    hosts: String(panel.knowledge.known),
    stale: String(panel.knowledge.stale),
    actions: String(panel.actions.length),
    operations: String(panel.operations.length),
  };
}

export function findHost(panel: Panel | null, id: number | null): HostView | null {
  if (!panel || id === null) {
    return null;
  }
  return panel.hosts.find(host => host.host === id) ?? null;
}
