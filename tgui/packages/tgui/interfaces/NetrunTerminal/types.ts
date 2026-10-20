export type NetNode = {
  address: string;
  name: string;
  type: string;
  x: number;
  y: number;
  security: number;
  online: boolean;
  access: number;
  entities: number;
  active: boolean;
  uplink: string | null;
};

export type NetCommand = {
  id: string;
  name: string;
  desc: string;
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
};

export const NODE_NAMES: Record<string, string> = {
  airlock: 'Шлюзы',
  apc: 'Щитки APC',
  camera: 'Камеры',
  turret: 'Турели',
  vendor: 'Торгоматы',
  terminal: 'Терминалы',
  server: 'Серверы',
  circuit: 'Схемы',
  intercom: 'Интеркомы',
  implant: 'Импланты',
  borg: 'Кибники',
  ai: 'ИИ',
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
