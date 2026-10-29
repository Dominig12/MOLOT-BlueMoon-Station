import type { Graphics } from 'pixi.js';

import { GlyphPrimitive, primitivePath, tracePrimitive } from './nodeGlyphs';

export type ProcessKind = 'entity' | 'bots' | 'ice' | 'police';
const poly = (...points: number[]): GlyphPrimitive => ({ kind: 'polyline', points, closed: true });
const line = (x1: number, y1: number, x2: number, y2: number): GlyphPrimitive => ({ kind: 'line', x1, y1, x2, y2 });
const shield = poly(-.9, -.9, .9, -.9, .9, .15, 0, 1, -.9, .15);
/** Shared silhouettes and pictograms remain recognisable in the legend and at map overview LOD. */
export const PROCESS_GLYPHS: Record<ProcessKind, { color: number; body: GlyphPrimitive; ink: GlyphPrimitive[] }> = {
  entity: { color: 0xf5a9e2, body: poly(0, -1, 1, 0, 0, 1, -1, 0), ink: [
    { kind: 'circle', x: 0, y: -.28, r: .2 }, poly(-.48, .45, -.33, .12, .33, .12, .48, .45),
  ] },
  bots: { color: 0xd8ef83, body: { kind: 'roundRect', x: -1, y: -.8, w: 2, h: 1.7, r: .25 }, ink: [
    line(0, -.8, 0, -1.2), line(-.55, -.15, -.25, -.15), line(.25, -.15, .55, -.15), line(-.4, .4, .4, .4),
  ] },
  ice: { color: 0xff8996, body: shield, ink: [
    line(0, -.6, 0, .5), line(-.48, -.35, .48, .25), line(-.48, .25, .48, -.35),
  ] },
  police: { color: 0x8dcaff, body: shield, ink: [
    poly(0, -.64, .17, -.21, .62, -.19, .28, .11, .38, .56, 0, .31, -.38, .56, -.28, .11, -.62, -.19, -.17, -.21),
  ] },
};
export const processSvgPaths = (kind: ProcessKind) => {
  const glyph = PROCESS_GLYPHS[kind];
  return { body: primitivePath(glyph.body), ink: glyph.ink.map(primitivePath).join(' ') };
};
export function drawProcessGlyph(graphics: Graphics, kind: ProcessKind, x: number, y: number, radius: number) {
  const glyph = PROCESS_GLYPHS[kind];
  tracePrimitive(graphics, glyph.body, x, y, radius);
  graphics.fill({ color: glyph.color }).stroke({ color: 0x07151f, width: radius * .32, alpha: .98 });
  tracePrimitive(graphics, glyph.body, x, y, radius);
  graphics.stroke({ color: 0xffffff, width: radius * .08, alpha: .7 });
  for (const primitive of glyph.ink) { tracePrimitive(graphics, primitive, x, y, radius); }
  graphics.stroke({ color: 0x10212b, width: radius * .16, cap: 'round', join: 'round' });
}
