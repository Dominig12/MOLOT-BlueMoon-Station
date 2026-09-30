import {
  type MouseEvent as ReactMouseEvent,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react';

import type { CircuitComponentView } from './types';

const MAP_W = 160;
const MAP_H = 104;
const DOT_SIZE = 4;
const MINIMAP_MARGIN = 60;

type MutableRef<T> = { current: T };

type MinimapProps = {
  components: (CircuitComponentView | null)[];
  backgroundXRef: MutableRef<number>;
  backgroundYRef: MutableRef<number>;
  zoomRef: MutableRef<number>;
  /** Основной SVG схемы — используется для замера видимой области (без transform-scale). */
  svgRef: MutableRef<SVGSVGElement | null>;
  /** Сместить вид так, чтобы мировая точка (wx, wy) попала в центр при текущем зуме. */
  onCenter: (wx: number, wy: number, zoom: number) => void;
};

type World = {
  pts: { x: number; y: number; color: string }[];
  minX: number;
  minY: number;
  maxX: number;
  maxY: number;
};

type ViewRect = { x: number; y: number; w: number; h: number };

/**
 * Миникарта: все узлы точками + рамка текущей видимой области. Точки и рамка
 * отрисовываются в фиксированных пикселях (не зависят от масштаба мира), что
 * читаемо при десятках чипов. Обновляется собственным RAF-циклом, читающим
 * ref-координаты панорамы/зума, — без перерисовки всего дерева схемы на каждый
 * кадр перетаскивания. Клик по миникарте центрирует вид на точке.
 */
export const Minimap = (props: MinimapProps) => {
  const {
    components,
    backgroundXRef,
    backgroundYRef,
    zoomRef,
    svgRef,
    onCenter,
  } = props;

  const mapRef = useRef<HTMLDivElement | null>(null);
  const [view, setView] = useState<ViewRect | null>(null);

  const world = useMemo<World | null>(() => {
    const pts: { x: number; y: number; color: string }[] = [];
    let minX = Infinity;
    let minY = Infinity;
    let maxX = -Infinity;
    let maxY = -Infinity;
    for (const comp of components) {
      if (!comp) {
        continue;
      }
      const x = comp.x || 0;
      const y = comp.y || 0;
      pts.push({ x, y, color: comp.color || '#5d7cc0' });
      if (x < minX) {
        minX = x;
      }
      if (y < minY) {
        minY = y;
      }
      if (x > maxX) {
        maxX = x;
      }
      if (y > maxY) {
        maxY = y;
      }
    }
    if (pts.length === 0) {
      return null;
    }
    return {
      pts,
      minX: minX - MINIMAP_MARGIN,
      minY: minY - MINIMAP_MARGIN,
      maxX: maxX + MINIMAP_MARGIN,
      maxY: maxY + MINIMAP_MARGIN,
    };
  }, [components]);

  useEffect(() => {
    let raf = 0;
    let lastKey = '';
    const tick = () => {
      raf = requestAnimationFrame(tick);
      const svg = svgRef.current;
      const z = Math.max(zoomRef.current || 1, 0.01);
      const vw = svg ? svg.offsetWidth : 0;
      const vh = svg ? svg.offsetHeight : 0;
      const x = -backgroundXRef.current / z;
      const y = -backgroundYRef.current / z;
      const w = vw / z;
      const h = vh / z;
      const key = `${x}|${y}|${w}|${h}`;
      if (key !== lastKey) {
        lastKey = key;
        setView({ x, y, w, h });
      }
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [svgRef, zoomRef, backgroundXRef, backgroundYRef]);

  if (!world) {
    return null;
  }

  const worldW = world.maxX - world.minX;
  const worldH = world.maxY - world.minY;
  const scale = Math.min(MAP_W / worldW, MAP_H / worldH);
  const offsetX = (MAP_W - worldW * scale) / 2;
  const offsetY = (MAP_H - worldH * scale) / 2;
  const toX = (wx: number) => offsetX + (wx - world.minX) * scale;
  const toY = (wy: number) => offsetY + (wy - world.minY) * scale;

  const handleClick = (e: ReactMouseEvent<HTMLDivElement>) => {
    const el = mapRef.current;
    if (!el) {
      return;
    }
    const r = el.getBoundingClientRect();
    const cx = e.clientX - r.left;
    const cy = e.clientY - r.top;
    const wx = world.minX + (cx - offsetX) / scale;
    const wy = world.minY + (cy - offsetY) / scale;
    onCenter(wx, wy, zoomRef.current || 1);
  };

  return (
    <div
      ref={mapRef}
      className="IntegratedCircuit__minimap"
      style={{ width: MAP_W, height: MAP_H }}
      onClick={handleClick}>
      {view && (
        <div
          className="IntegratedCircuit__minimapViewport"
          style={{
            left: toX(view.x),
            top: toY(view.y),
            width: view.w * scale,
            height: view.h * scale,
          }}
        />
      )}
      {world.pts.map((p, i) => (
        <div
          key={i}
          className="IntegratedCircuit__minimapDot"
          style={{
            left: toX(p.x) - DOT_SIZE / 2,
            top: toY(p.y) - DOT_SIZE / 2,
            backgroundColor: p.color,
          }}
        />
      ))}
    </div>
  );
};