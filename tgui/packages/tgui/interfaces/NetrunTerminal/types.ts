export type NetNode = {
  address: string;
  name: string;
  type: string;
  x: number;
  y: number;
  z?: number;
  /** Movable endpoints are rendered by the reactive layer above the stationary canvas. */
  dynamic?: boolean;
  security: number;
  online: boolean;
  access: number;
  can_hop?: boolean;
  entities: number;
  ice?: number;
  active: boolean;
  uplink: string | null;
  apc?: string | null;
  network?: string;
  sector?: string;
};

export type NetCommand = {
  id: string;
  name: string;
  desc: string;
  help?: string;
  icon: string;
  danger: boolean;
  access: number;
  allowed: boolean;
  illegal: boolean;
  trace: number;
};

export type NetFile = {
  uid: string;
  name: string;
  kind: string;
  size: number;
  preview: string | null;
  selected?: boolean;
};

export type Storage = {
  files: NetFile[];
  used: number;
  capacity: number;
};

export type SelectedNode = NetNode & {
  network: string;
  legit: number;
  commands: NetCommand[];
  status: string[];
  logs?: string[];
  files?: NetFile[];
  storage?: { used: number; capacity: number };
  lan?: {
    id: string;
    code: string;
    name: string;
    color: string;
    security: number;
    access: number;
    has_key: boolean;
    can_breach: boolean;
  };
};

export type NetworkEntry = {
  id: string;
  name: string;
  short: string;
  code: string;
  color: string;
  security: number;
  isolated: boolean;
  home: boolean;
  reachable: boolean;
  access: number;
  has_key: boolean;
  can_breach: boolean;
  nodes: number;
};

export type NetworkView = {
  id: string;
  name: string;
  code: string;
  color: string;
  access: number;
  nodes: NetNode[];
  log: string[];
};

export type Daemon = {
  name: string;
  reward: number;
  sequence: string[];
  done: boolean;
};

export type MatrixState = {
  minigame?: 'matrix' | 'sequence' | 'automatic';
  target: string;
  security: number;
  size: number;
  cells: {
    code: string | null;
    active: boolean;
    order?: number;
    done?: boolean;
  }[];
  buffer?: string[];
  buffer_size?: number;
  daemons: Daemon[];
  time_left: number;
  pick_row?: boolean;
  progress?: number;
  total?: number;
};

export type LogLine = { time?: string; text: string; kind: string };

export type HostAction = { id: string; name: string; icon: string };

export type EntityState = {
  name: string;
  integrity: number;
  max_integrity: number;
  host: string | null;
  host_name: string | null;
  diving: boolean;
  travel?: { target: string; remaining: number } | null;
};

export type CombatTarget = {
  ref: string;
  name: string;
  kind: 'entity' | 'ice';
  hostile: boolean;
  integrity: number;
  max_integrity: number;
  stunned: boolean;
  programs?: EnemyProgram[];
  shielded?: boolean;
  casting?: IncomingProgram | null;
  node?: string | null;
  node_name?: string | null;
  unavailable_reason?: string | null;
};

export type IncomingProgram = { name: string; role: string; power: number; remaining: number; source?: string; source_ref?: string; source_node?: string | null };
export type EnemyProgram = { name: string; desc: string; role: string; power: number; cooldown: number; windup: number; ready_in: number };

export type CombatProgram = {
  id: string;
  uid: string;
  name: string;
  desc: string;
  size: number;
  role: string;
  power: number;
  cooldown: number;
  consumable: boolean;
  needs_target: boolean;
  icon: string;
  ready_in: number;
  unavailable_reason?: string | null;
};

export type CombatState = {
  node: string | null;
  node_name: string | null;
  self: { integrity: number; max_integrity: number; stunned: boolean; shielded?: boolean } | null;
  targets: CombatTarget[];
  programs: CombatProgram[];
  incoming?: IncomingProgram[];
  loot?: NetFile[];
};

export type SearchResult = {
  address: string;
  name: string;
  type: string;
  network: string | null;
  online: boolean;
  visible: boolean;
};

export type WorkspaceView = 'terminal' | 'map' | 'files' | 'pinned' | 'combat' | 'breach' | 'web';

export type NetrunData = {
  workspace_view?: WorkspaceView;
  origin: string;
  wireless: boolean;
  uplink: boolean;
  trace: number;
  locked: number;
  can_breach: boolean;
  can_autobreach?: boolean;
  log: LogLine[];
  jack: { address: string; name: string } | null;
  host_actions: HostAction[];
  networks: NetworkEntry[];
  view: NetworkView | null;
  selected: SelectedNode | null;
  storage: Storage;
  shard: (Storage & { name: string }) | null;
  breach: MatrixState | null;
  entity: EntityState | null;
  combat: CombatState | null;
  chat: { handle: string; messages: string[] };
  web: WebState | null;
  cli?: {
    verbs: {
      id: string;
      args: string;
      desc: string;
      category?: string;
      completions?: string[];
      completion_key?: string;
    }[];
    completions?: Record<string, string[]>;
  };
  windows: WindowTab[];
  window: MachineWindow | null;
  map: NetMapPacket | null;
  selected_network: SelectedNetwork | null;
  ping_route: PingHop[] | null;
  events?: NetEvent[] | null;
  waypoint?: Waypoint | null;
  search?: SearchResult[] | null;
  file?: (NetFile & {
    content: string | null;
    image: string | null;
    width?: number;
    height?: number;
    source: 'local' | 'shard';
  }) | null;
};

export type PingHop = { kind: 'node' | 'gateway' | 'hub'; ref?: string };

export type Waypoint = {
  address: string;
  name: string;
  type?: string;
  reachable: boolean;
  hops: number;
  route: string[];
  next: string | null;
  lost?: boolean;
};

export type NetEvent = {
  kind: 'command' | 'intrusion' | 'breach' | 'trace';
  from: string | null;
  to: string | null;
  age: number;
};

export type Gateway = {
  id: string;
  code: string;
  name: string;
  color: string;
  security: number;
  access: number;
  has_key: boolean;
  can_breach: boolean;
};

export type NetEdge = {
  id: string;
  from: string;
  to: string;
  kind: 'endpoint' | 'apc' | 'relay';
  online?: boolean;
};

export type NetMap = {
  /** A full baseline for one authorized UI stream; omitted by legacy payloads. */
  epoch?: string;
  full?: true | 1;
  gateways: Gateway[];
  nodes: NetNode[];
  edges: NetEdge[];
  focus: string | null;
  revision: number;
  /** Per-console projected graph generations; legacy snapshots use semantic comparison. */
  structure_revision?: number;
  state_revision?: number;
  /** Stationary geometry/status only; actor movement and activity do not advance it. */
  static_revision?: number;
  source_sector?: string | null;
  source_z?: number | null;
  active_sector?: string | null;
  active_z?: number | null;
  sectors?: { id: string; name: string; levels: number[] }[];
  apc_zones?: ApcZone[];
  relay_destinations?: RelayDestination[];
  /** Server-cached path to the selected target; latency is milliseconds. */
  route?: {
    route: string[];
    hops: number;
    latency: number;
    revision: number;
    reachable: boolean;
  } | null;
};

/** Graph entries are upserts; unchanged stationary entries are not transported again. */
export type NetMapDelta = Partial<Omit<NetMap, 'nodes' | 'edges' | 'full' | 'state_revision'>> & {
  epoch: string;
  full: false | 0;
  base_revision: number;
  state_revision: number;
  nodes?: NetNode[];
  edges?: NetEdge[];
  removed_nodes?: string[];
  removed_edges?: string[];
};
export type NetMapPacket = NetMap | NetMapDelta;

export type ApcZone = { address: string; z: number; runs: { x: number; y: number; width: number }[] };
export type RelayDestination = {
  from: string; to: string; name: string; sector: string; z: number;
  online: boolean; can_hop: boolean; unavailable_reason?: string | null;
};

export type SelectedNetwork = {
  id: string;
  code: string;
  name: string;
  color: string;
  security: number;
  access: number;
  has_key: boolean;
  can_breach: boolean;
  log: string[];
};

export type WindowTab = {
  address: string;
  title: string;
  type: string;
  online: boolean;
};

export type WindowAction = {
  id: string;
  name: string;
  icon: string;
  access: number;
  danger?: boolean;
  desc?: string;
  allowed: boolean;
};

export type MachineWindow = {
  address: string;
  title: string;
  type: string;
  online: boolean;
  access: number;
  legit?: number;
  security?: number;
  can_breach?: boolean;
  network?: {
    id: string;
    name: string;
    code: string;
    access: number;
    can_breach: boolean;
  };
  fields: string[];
  commands: NetCommand[];
  extra: WindowAction[];
  feed: string[] | null;
  watching: boolean;
  logs?: string[];
  remote?: {
    interface: string;
    data: Record<string, unknown>;
    actions: {
      id: string;
      name: string;
      desc?: string;
      access: number;
      allowed: boolean;
      danger?: boolean;
      reason?: string | null;
      params?: { id: string; name: string; type: 'text' | 'number'; value?: string | number; min?: number; max?: number }[];
    }[];
  } | null;
};

export type WebSite = { id: string; domain: string; title: string };

export type WebState = {
  available: boolean;
  sites: WebSite[];
  site: {
    id: string;
    domain: string;
    title: string;
    pages: { slug: string; title: string }[];
  } | null;
  page: {
    slug: string;
    title: string;
    text: string | null;
    loading: boolean;
    failed: boolean;
  } | null;
};

export const ACCESS_NAMES = ['НЕТ', 'ГОСТЬ', 'ПОЛЬЗОВАТЕЛЬ', 'ROOT'];
export const ACCESS_COLORS = ['#59606e', '#8b93a3', '#4ac0ff', '#3cdc8c'];

export const NODE_ICONS: Record<string, string> = {
  atmos: 'wind',
  relay: 'tower-broadcast',
  airlock: 'door-closed',
  apc: 'car-battery',
  camera: 'video',
  optic: 'glasses',
  turret: 'crosshairs',
  vendor: 'shop',
  terminal: 'desktop',
  server: 'server',
  circuit: 'microchip',
  intercom: 'microphone',
  implant: 'brain',
  borg: 'robot',
  ai: 'network-wired',
  gateway: 'network-wired',
  neural: 'brain',
  pai: 'robot',
  deck: 'keyboard',
};

export const NODE_NAMES: Record<string, string> = {
  atmos: 'Атмосфера',
  relay: 'Реле NTnet',
  airlock: 'Шлюзы',
  apc: 'Щитки APC',
  camera: 'Камеры',
  optic: 'HUD-очки',
  turret: 'Турели',
  vendor: 'Торгоматы',
  terminal: 'Терминалы',
  server: 'Серверы',
  circuit: 'Схемы',
  intercom: 'Интеркомы',
  implant: 'Импланты',
  borg: 'Кибники',
  ai: 'ИИ',
  gateway: 'Шлюзы сетей',
  neural: 'Нейроинтерфейсы',
  pai: 'пИИ',
  deck: 'Кибердеки',
};

export const THEME = {
  bg: '#0b0e14',
  panel: '#111620',
  line: '#1f2a3a',
  text: '#d4dcea',
  muted: '#6f7a8c',
  accent: '#4ac0ff',
  good: '#3cdc8c',
  warn: '#f0b040',
  bad: '#ff5c6c',
};
