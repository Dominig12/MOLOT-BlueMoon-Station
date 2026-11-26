import { BooleanLike } from 'common/react';

/** What one observer may see of one digital host. Names arrive only once the identity is established. */
/** One strain of the observer: a virus that spreads or ICE that defends, with what is left of it. */
export type AgentView = {
  id: number;
  strain: string;
  kind: string;
  host: number;
  generation: number;
  integrity: number;
  spreads: number;
};

/** A stored copy of a core: what it holds, how intact it is and when it was taken. */
export type BackupView = {
  id: number;
  host: number;
  integrity: number;
  control: number;
  takenAt: number;
};

/** One digital core of the observer: what it is, how hurt it is and which generation controls it. */
export type LifeView = {
  identity: number;
  host: number;
  state: string;
  integrity: number;
  control: number;
  migrating: BooleanLike;
  destination: number;
};

/** Where the operator's own presence stands, as the Host reports it. */
export type PresenceView = {
  identity: number;
  host: number;
  state: string;
  destination: number;
  hops: number;
  arriveAt: number;
};

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
  /** The host's own alert level (§9.3). Absent in older projections, so it stays optional. */
  alert?: string;
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

/**
 * The observer's own request as the traffic tab shows it: what was asked, between which hosts, when and with
 * what outcome. It is the request, not a packet trace: NETDM owns the route and this view never invents one.
 */
export type TrafficView = {
  operation: number;
  kind: string;
  category: string;
  status: string;
  from: number;
  to: number;
  at: number;
  doneAt: number;
  reason: string | null;
};

export type LinkView = { a: number; b: number; cost: number };

/**
 * Real movement the Host let this observer see (UI-003, §15.2): its own presence, or another presence only
 * while it travels between two hosts that are already on the map. Times are game milliseconds, so the marker
 * moves with the simulation and not with the browser clock.
 */
export type VisualView = {
  kind: string;
  own: BooleanLike;
  host: number;
  destination: number;
  state: string;
  hops: number;
  startedAt: number;
  arriveAt: number;
};

/** One marker the map can draw: where a move left, where it goes and how far along it is. */
export type TravelMarker = {
  from: number;
  to: number;
  own: boolean;
  travelling: boolean;
  progress: number;
};

/** Which layers of the map are drawn. Unknown host stays out of every layer, whatever the switch says. */
export type MapLayers = {
  movement: boolean;
  alerts: boolean;
  freshOnly: boolean;
};

export const DEFAULT_LAYERS: MapLayers = { movement: true, alerts: true, freshOnly: false };

/** A starting program as text. It is data: importing it never carries rights or an old host identifier. */
export type PresetView = { name: string; text: string };

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
  /** Movement the observer may see. Absent in older projections, so it stays optional. */
  visuals?: VisualView[];
  actions: ActionView[];
  operations: OperationView[];
  /** This observer's own requests with the hosts they went between. Absent in older projections. */
  traffic?: TrafficView[];
  programs: ProgramView[];
  /** The observer's own strains. */
  agents: AgentView[];
  /** Copies of the observer's own core, newest first. */
  backups: BackupView[];
  /** The observer's own cores: their lives are not somebody else's business either. */
  lives: LifeView[];
  /** Only the observer's own presence: another runner's is not this window's business. */
  presence: PresenceView | null;
  presences: PresenceView[];
  presets: PresetView[];
  knowledge: { known: number; stale: number; total: number };
};

export type Data = { panel: Panel | null; error: string | null; notice: string | null };

export type TabKey = 'network' | 'traffic' | 'hosts' | 'programs' | 'life' | 'agents' | 'events';

export const TABS: { key: TabKey; label: string; icon: string }[] = [
  { key: 'network', label: 'Сеть', icon: 'diagram-project' },
  { key: 'traffic', label: 'Трафик', icon: 'network-wired' },
  { key: 'hosts', label: 'Хосты', icon: 'server' },
  { key: 'programs', label: 'Программы', icon: 'code' },
  { key: 'life', label: 'Ядро', icon: 'brain' },
  { key: 'agents', label: 'Агенты', icon: 'bug' },
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

/**
 * How a request reads in the traffic tab: in flight is decided by the operation itself (no completion time),
 * not by a guess about the route. A request that never finished is shown as such rather than as a success.
 */
export function trafficState(entry: TrafficView): 'in_flight' | 'done' {
  return !entry.doneAt || entry.doneAt <= 0 ? 'in_flight' : 'done';
}

/** Round-trip time of a finished request, or null while it is still open. */
export function trafficLatency(entry: TrafficView): number | null {
  if (trafficState(entry) === 'in_flight' || entry.doneAt < entry.at) {
    return null;
  }
  return entry.doneAt - entry.at;
}

/** Lines of the traffic tab, newest first, with the latency already resolved. */
export function trafficRows(traffic: TrafficView[] | undefined): (TrafficView & { latency: number | null })[] {
  return [...(traffic ?? [])]
    .sort((left, right) => right.operation - left.operation)
    .map(entry => ({ ...entry, latency: trafficLatency(entry) }));
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

/**
 * How far along a move is, on a 0..1 scale. Outside its own window the marker stays at an end instead of
 * looping: a projection that arrives late shows the move finished, never a jump back to the start.
 */
export function travelProgress(startedAt: number, arriveAt: number, now: number): number {
  const span = arriveAt - startedAt;
  if (!(span > 0)) {
    return 1;
  }
  return Math.min(1, Math.max(0, (now - startedAt) / span));
}

/**
 * Markers for the movement layer. A host the projection did not reveal is never drawn, so a move is shown
 * only when both of its ends are on the map. A resting stranger is not drawn at all: the layer shows motion,
 * not where somebody stands (AT-12). The input is anything with hosts and visuals, so a panel and a prepared
 * map view both work.
 */
export function travelMarkers(
  input: { hosts: HostView[]; visuals?: VisualView[]; now?: number } | null,
  layers: MapLayers = DEFAULT_LAYERS,
): TravelMarker[] {
  if (!input?.visuals?.length) {
    return [];
  }
  const shown = new Set(visibleHosts(input.hosts ?? [], layers.freshOnly).map(host => host.host));
  const now = input.now ?? 0;
  const markers: TravelMarker[] = [];
  for (const visual of input.visuals) {
    const from = Number(visual.host);
    if (!from || !shown.has(from)) {
      continue;
    }
    const to = Number(visual.destination);
    const travelling = String(visual.state) === 'traveling' && !!to && to !== from && shown.has(to);
    const own = !!visual.own;
    if (!travelling && !own) {
      continue;
    }
    markers.push({
      from,
      to: travelling ? to : from,
      own,
      travelling,
      progress: travelling ? travelProgress(Number(visual.startedAt), Number(visual.arriveAt), now) : 0,
    });
  }
  return markers;
}

/** The point a marker stands at: interpolation along the edge it travels. */
export function pointAlong(
  from: { x: number; y: number },
  to: { x: number; y: number },
  progress: number,
): { x: number; y: number } {
  const step = Math.min(1, Math.max(0, progress));
  return {
    x: from.x + (to.x - from.x) * step,
    y: from.y + (to.y - from.y) * step,
  };
}

/**
 * Ring colour for a host's own alert (§9.3). Colour is never the only signal: the map also writes the level
 * next to the label, so a monochrome screen loses nothing.
 */
export function alertStroke(alert?: string): string | null {
  switch (String(alert || 'Normal')) {
    case 'Suspicious':
      return 'rgba(226, 196, 84, 0.9)';
    case 'Alert':
      return 'rgba(236, 142, 60, 0.95)';
    case 'Hostile':
      return 'rgba(230, 74, 64, 1)';
    case 'Lockdown':
      return 'rgba(198, 62, 196, 1)';
    default:
      return null;
  }
}

/** Short word for the alert level, written on the map so the ring is not the only hint. */
export function alertShort(alert?: string): string {
  switch (String(alert || 'Normal')) {
    case 'Suspicious':
      return 'насторожен';
    case 'Alert':
      return 'тревога';
    case 'Hostile':
      return 'враждебно';
    case 'Lockdown':
      return 'блокировка';
    default:
      return '';
  }
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
