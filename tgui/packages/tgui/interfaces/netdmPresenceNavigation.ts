import { isOffline, View } from './NetdmTopology/model';

export type KnownShell = {
  instance: string;
  type: string;
  node: string;
  stale: number | boolean;
};

export type NearbyDestination = {
  node: string;
  instance: string;
  radio: boolean;
  unavailable: boolean;
};

/**
 * Known one-hop targets are suggestions, NOT proof of reachability.
 * Even a usable link still requires Host preview_move and a real move receipt.
 * Unseen nodes, unregistered shells and stale providers never become invented routes.
 */
export const nearbyDestinations = (
  view: View,
  currentNode: string | null,
  services: readonly KnownShell[],
  max = 6,
): NearbyDestination[] => {
  if (!currentNode || !view.nodes.has(currentNode)) {
    return [];
  }
  const shells = new Map<string, KnownShell>();
  for (const service of services) {
    if (service.type === 'network.shell' && view.nodes.has(service.node) && !shells.has(service.node)) {
      shells.set(service.node, service);
    }
  }
  const targets = new Map<string, { destination: NearbyDestination; down: boolean }>();
  for (const link of view.links.values()) {
    if (link.a !== currentNode && link.b !== currentNode) {
      continue;
    }
    const node = link.a === currentNode ? link.b : link.a;
    const target = view.nodes.get(node);
    const shell = shells.get(node);
    if (!target || !shell) {
      continue;
    }
    const destination: NearbyDestination = {
      node,
      instance: shell.instance,
      radio: link.radio,
      unavailable: link.down || isOffline(target.flags) || !!shell.stale,
    };
    const previous = targets.get(node);
    // A silent wire never overrides a known live radio connection, even if the
    // provider itself is stale; prefer working links before comparing their medium.
    if (!previous || (previous.down && !link.down) ||
        (previous.down === link.down &&
          previous.destination.unavailable && !destination.unavailable) ||
        (previous.down === link.down &&
          previous.destination.unavailable === destination.unavailable &&
          previous.destination.radio && !destination.radio)) {
      targets.set(node, { destination, down: link.down });
    }
  }
  return [...targets.values()].map(value => value.destination)
    .sort((a, b) => Number(a.unavailable) - Number(b.unavailable) ||
      Number(a.radio) - Number(b.radio) || a.node.localeCompare(b.node, undefined, { numeric: true }))
    .slice(0, Math.max(0, Math.min(12, max)));
};

/** Known adjacent nodes can always be inspected; adjacency does not establish reachability. */
export type NearbyNode = { node: string; radio: boolean; unavailable: boolean };

export const knownAdjacentNodes = (view: View, anchor: string | null, max = 8): NearbyNode[] => {
  const source = anchor ? view.nodes.get(anchor) : undefined;
  if (!source) {
    return [];
  }
  const adjacent = new Map<string, { value: NearbyNode; down: boolean }>();
  for (const link of view.links.values()) {
    if (link.a !== anchor && link.b !== anchor) {
      continue;
    }
    const id = link.a === anchor ? link.b : link.a;
    const node = view.nodes.get(id);
    if (!node) {
      continue;
    }
    const value: NearbyNode = {
      node: id,
      radio: link.radio,
      unavailable: link.down || isOffline(source.flags) || isOffline(node.flags),
    };
    const previous = adjacent.get(id);
    // Prefer live radio over a broken wire; no link here grants permission to travel.
    if (!previous || (previous.down && !link.down) ||
        (previous.down === link.down && previous.value.unavailable && !value.unavailable) ||
        (previous.down === link.down && previous.value.unavailable === value.unavailable &&
          previous.value.radio && !value.radio)) {
      adjacent.set(id, { value, down: link.down });
    }
  }
  return [...adjacent.values()].map(entry => entry.value)
    .sort((a, b) => Number(a.unavailable) - Number(b.unavailable) ||
      Number(a.radio) - Number(b.radio) || a.node.localeCompare(b.node, undefined, { numeric: true }))
    .slice(0, Math.max(0, Math.min(12, max)));
};
