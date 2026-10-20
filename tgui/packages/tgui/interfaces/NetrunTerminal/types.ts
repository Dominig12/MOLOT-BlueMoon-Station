export type NetNode = {
  address: string;
  name: string;
  type: string;
  x: number;
  y: number;
  z?: number;
  security: number;
  online: boolean;
  access: number;
  entities: number;
  active: boolean;
  uplink: string | null;
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
  target: string;
  security: number;
  size: number;
  cells: { code: string | null; active: boolean }[];
  buffer: string[];
  buffer_size: number;
  daemons: Daemon[];
  time_left: number;
  pick_row: boolean;
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
};

export type NetrunData = {
  origin: string;
  wireless: boolean;
  uplink: boolean;
  trace: number;
  locked: number;
  can_breach: boolean;
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
  chat: { handle: string; messages: string[] };
  web: WebState | null;
  cli?: {
    verbs: {
      id: string;
      args: string;
      desc: string;
      category?: string;
      completions?: string[];
    }[];
  };
  windows: WindowTab[];
  window: MachineWindow | null;
  map: NetMap | null;
  selected_network: SelectedNetwork | null;
  ping_route: PingHop[] | null;
  events?: NetEvent[] | null;
  waypoint?: Waypoint | null;
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
  gateways: Gateway[];
  nodes: NetNode[];
  edges: NetEdge[];
  focus: string | null;
  depth: number;
  revision: number;
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
      params?: { id: string; name: string; type: 'text' | 'number'; value?: string; min?: number; max?: number }[];
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
