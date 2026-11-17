import { isOffline, View } from './NetdmTopology/model';

export type PresenceShell = {
  node: string;
  type: string;
  instance: string;
  stale?: number | boolean;
};

export type NodeTravelChoice = {
  state: 'here' | 'unknown' | 'offline' | 'no_shell' | 'stale' | 'ready';
  /** The actual registered network.shell instance, never a node-derived guess. */
  instance: string | null;
};

/**
 * Translate the selected known node into a possible destination for preview_move.
 * This is NOT a connectivity or access check. Only Host can confirm a valid route.
 * Do not leak undiscovered services or infer a shell from the node ID.
 */
export const nodeTravelChoice = (
  view: View,
  selected: string | null,
  current: string | null,
  services: readonly PresenceShell[],
): NodeTravelChoice => {
  if (!selected || !view.nodes.has(selected)) {
    return { state: 'unknown', instance: null };
  }
  if (selected === current) {
    return { state: 'here', instance: null };
  }
  const node = view.nodes.get(selected)!;
  if (isOffline(node.flags)) {
    return { state: 'offline', instance: null };
  }
  const shells = services.filter(service => service.node === selected && service.type === 'network.shell');
  const ready = shells.find(service => !service.stale);
  if (ready) {
    return { state: 'ready', instance: ready.instance };
  }
  return shells.length
    ? { state: 'stale', instance: null }
    : { state: 'no_shell', instance: null };
};

export const isSelectedPreview = (choice: NodeTravelChoice, preview: {
  target?: string | null;
  status?: string | null;
} | null): boolean =>
  choice.state === 'ready' && !!preview && choice.instance === preview.target &&
  preview.status === 'ready';
