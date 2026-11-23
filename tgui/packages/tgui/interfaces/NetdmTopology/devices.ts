import { FLAG_ACCESS_POINT, FLAG_APC, ViewNode } from './model';

export const DEVICE_TYPES = {
  apc: { label: 'АПЦ', icon: 'bolt', color: 0x86b8ff },
  camera: { label: 'Камера', icon: 'video', color: 0x8be3f5 },
  door: { label: 'Дверь или шлюз', icon: 'door-closed', color: 0xffcd8e },
  airAlarm: { label: 'Панель атмосферы', icon: 'heartbeat', color: 0x73e2cb },
  airSensor: { label: 'Датчик атмосферы', icon: 'tachometer-alt', color: 0x73e2cb },
  messenger: { label: 'Устройство с мессенджером', icon: 'mobile-alt', color: 0xbcabff },
  mailServer: { label: 'Сервер сообщений', icon: 'envelope', color: 0xbcabff },
  research: { label: 'Сервер исследований', icon: 'server', color: 0xa6d4ff },
  radio: { label: 'Радиоузел', icon: 'broadcast-tower', color: 0xffbd83 },
  machine: { label: 'Управляемый механизм', icon: 'power-off', color: 0xa6e5a8 },
  shell: { label: 'Узел с сетевой оболочкой', icon: 'terminal', color: 0xb9cadd },
  generic: { label: 'Узел неизвестного типа', icon: 'crosshairs', color: 0xa6b4c3 },
} as const;

type DeviceKind = keyof typeof DEVICE_TYPES;
export type DeviceAppearance = { kind: DeviceKind; stale: boolean };
export type DeviceKinds = ReadonlyMap<string, DeviceAppearance>;
export type DeviceService = { node: string; type: string; stale?: boolean | number };

// When a node offers more than one service, prefer a fresh device capability over its shell.
const SERVICES = new Map<string, readonly [DeviceKind, number]>([
  ['camera.access', ['camera', 0]],
  ['machine.door', ['door', 1]],
  ['atmos.alarm', ['airAlarm', 2]],
  ['atmos.telemetry', ['airSensor', 3]],
  ['pda.server', ['mailServer', 4]],
  ['research.server', ['research', 5]],
  ['pda.messenger', ['messenger', 6]],
  ['radio.receiver', ['radio', 7]],
  ['machine.control', ['machine', 8]],
  ['network.shell', ['shell', 9]],
]);

export const classifyDevices = (
  nodes: ReadonlyMap<string, ViewNode>,
  services: readonly DeviceService[],
): DeviceKinds => {
  const matched = new Map<string, DeviceAppearance & { priority: number }>();
  for (const service of services) {
    // Services on other levels and records for undiscovered nodes are not shown.
    if (!nodes.has(service.node)) continue;
    const entry = SERVICES.get(service.type);
    if (!entry) continue;
    const [kind, order] = entry;
    const stale = !!service.stale;
    const priority = kind === 'shell' ? Infinity : order + (stale ? SERVICES.size : 0);
    const before = matched.get(service.node);
    if (!before || priority < before.priority || priority === before.priority && before.stale && !stale) {
      matched.set(service.node, { kind, stale, priority });
    }
  }

  const kinds = new Map<string, DeviceAppearance>();
  for (const [id, node] of nodes) {
    const known = matched.get(id);
    if (node.flags & FLAG_APC) {
      kinds.set(id, { kind: 'apc', stale: false });
    } else if (known) {
      kinds.set(id, { kind: known.kind, stale: known.stale });
    } else {
      kinds.set(id, { kind: node.flags & FLAG_ACCESS_POINT ? 'radio' : 'generic', stale: false });
    }
  }
  return kinds;
};
