import { GraphicsContext } from 'pixi.js';

import { DEVICE_TYPES, DeviceAppearance } from './devices';

type Ink = { color: number; width: number; cap: 'round'; join: 'round' };
type Glyph = (context: GraphicsContext, ink: Ink) => void;

// The chip is eight world units wide before the scene scales it to screen pixels.
const GLYPHS: Record<DeviceAppearance['kind'], Glyph> = {
  apc: (ctx, { color }) => {
    ctx.moveTo(0.6, -2.85).lineTo(-1.8, 0.25).lineTo(-0.25, 0.25).lineTo(-0.65, 2.85)
      .lineTo(1.85, -0.65).lineTo(0.2, -0.65).closePath().fill(color);
  },
  camera: (ctx, ink) => {
    ctx.roundRect(-2.7, -1.65, 3.75, 3.3, 0.5).stroke(ink);
    ctx.moveTo(1.1, -0.65).lineTo(2.8, -1.65).lineTo(2.8, 1.65).lineTo(1.1, 0.65).stroke(ink);
  },
  door: (ctx, ink) => {
    ctx.roundRect(-2.2, -2.65, 4.4, 5.3, 0.45).stroke(ink);
    ctx.moveTo(0, -2.5).lineTo(0, 2.5).moveTo(-1.3, 0.2).lineTo(-0.85, 0.2)
      .moveTo(0.85, 0.2).lineTo(1.3, 0.2).stroke(ink);
  },
  airAlarm: (ctx, ink) => {
    ctx.moveTo(-2.75, 0.5).lineTo(-1.35, 0.5).lineTo(-0.65, -1.9).lineTo(0.55, 2)
      .lineTo(1.35, -0.25).lineTo(2.75, -0.25).stroke(ink);
  },
  airSensor: (ctx, ink) => {
    ctx.circle(0, 0, 2.35).stroke(ink);
    ctx.moveTo(0, 0.3).lineTo(1.25, -1).stroke(ink);
    ctx.circle(0, 0.3, 0.48).fill(ink.color);
  },
  messenger: (ctx, ink) => {
    ctx.roundRect(-1.65, -2.75, 3.3, 5.5, 0.55).stroke(ink);
    ctx.moveTo(-0.6, 1.55).lineTo(0.6, 1.55).stroke(ink);
  },
  mailServer: (ctx, ink) => {
    ctx.roundRect(-2.65, -1.85, 5.3, 3.7, 0.45).stroke(ink);
    ctx.moveTo(-2.4, -1.45).lineTo(0, 0.4).lineTo(2.4, -1.45).stroke(ink);
  },
  research: (ctx, ink) => {
    ctx.roundRect(-2.5, -2.2, 5, 1.6, 0.35).stroke(ink);
    ctx.roundRect(-2.5, 0.6, 5, 1.6, 0.35).stroke(ink);
    ctx.circle(1.15, -1.4, 0.32).fill(ink.color);
    ctx.circle(1.15, 1.4, 0.32).fill(ink.color);
  },
  radio: (ctx, ink) => {
    ctx.moveTo(-2.2, -2.1).quadraticCurveTo(-3.3, -0.75, -2.2, 0.55)
      .moveTo(2.2, -2.1).quadraticCurveTo(3.3, -0.75, 2.2, 0.55)
      .moveTo(0, 0).lineTo(0, 2.65).stroke(ink);
    ctx.circle(0, -0.75, 0.75).fill(ink.color);
  },
  machine: (ctx, ink) => {
    ctx.moveTo(-1.55, -1.45).quadraticCurveTo(-3.65, 0.75, -1.35, 2.3)
      .quadraticCurveTo(0, 3.1, 1.35, 2.3).quadraticCurveTo(3.65, 0.75, 1.55, -1.45)
      .moveTo(0, -2.65).lineTo(0, -0.1).stroke(ink);
  },
  shell: (ctx, ink) => {
    ctx.moveTo(-2.55, -1.55).lineTo(-0.75, 0).lineTo(-2.55, 1.55)
      .moveTo(0.3, 1.55).lineTo(2.5, 1.55).stroke(ink);
  },
  generic: (ctx, ink) => {
    ctx.moveTo(0, -2.15).lineTo(2.15, 0).lineTo(0, 2.15).lineTo(-2.15, 0).closePath().stroke(ink);
  },
};

export const drawNodeBadge = (kind: DeviceAppearance['kind'], muted: boolean): GraphicsContext => {
  const border = muted ? 0x566477 : DEVICE_TYPES[kind].color;
  const ctx = new GraphicsContext();
  ctx.roundRect(-4.2, -4.2, 8.4, 8.4, 2.1)
    .fill(muted ? 0x182330 : 0x101e2c)
    .stroke({ width: 0.5, color: border });
  GLYPHS[kind](ctx, { color: muted ? 0x9baab9 : border, width: 0.68, cap: 'round', join: 'round' });
  return ctx;
};
