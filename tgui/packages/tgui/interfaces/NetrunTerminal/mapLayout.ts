type Position = { address: string; px: number; py: number };

/** Preserve cached positions and place changed nodes near their physical position.
 * Spatial buckets avoid comparing every pair of station devices on each update.
 */
export const spreadNodes = <T extends Position>(nodes: T[], fixed: Set<string>, gap: number) => {
  if (nodes.every((node) => fixed.has(node.address))) {
    return;
  }
  const buckets = new Map<string, T[]>();
  const key = (x: number, y: number) => `${Math.floor(x / gap)},${Math.floor(y / gap)}`;
  const insert = (node: T) => {
    const cell = key(node.px, node.py);
    const bucket = buckets.get(cell);
    if (bucket) {
      bucket.push(node);
    } else {
      buckets.set(cell, [node]);
    }
  };
  const free = (x: number, y: number) => {
    const cx = Math.floor(x / gap);
    const cy = Math.floor(y / gap);
    for (let dx = -1; dx <= 1; dx++) {
      for (let dy = -1; dy <= 1; dy++) {
        for (const other of buckets.get(`${cx + dx},${cy + dy}`) ?? []) {
          if (Math.hypot(x - other.px, y - other.py) < gap - 0.001) {
            return false;
          }
        }
      }
    }
    return true;
  };
  for (const node of nodes) {
    if (fixed.has(node.address)) {
      insert(node);
    }
  }
  const cursors = new Map<string, number>();
  for (const node of nodes) {
    if (fixed.has(node.address)) {
      continue;
    }
    const ox = node.px;
    const oy = node.py;
    if (!free(ox, oy)) {
      const cell = key(ox, oy);
      let index = cursors.get(cell) ?? 1;
      while (true) {
        const ring = Math.ceil((Math.sqrt(index + 1) - 1) / 2);
        const side = ring * 2;
        const offset = index - (2 * ring - 1) ** 2;
        const edge = Math.floor(offset / side);
        const step = offset % side;
        const dx = edge === 0 ? ring : edge === 1 ? ring - step : edge === 2 ? -ring : -ring + step;
        const dy = edge === 0 ? -ring + step : edge === 1 ? ring : edge === 2 ? ring - step : -ring;
        index++;
        if (free(ox + dx * gap, oy + dy * gap)) {
          node.px = ox + dx * gap;
          node.py = oy + dy * gap;
          cursors.set(cell, index);
          break;
        }
      }
    }
    insert(node);
  }
};
