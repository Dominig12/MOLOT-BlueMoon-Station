import {
  type MouseEvent as ReactMouseEvent,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react';

import type { CircuitComponentView } from './types';

const MAP_W = 160;
const MAP_H = 104;
const DOT_SIZE = 4;
/** Мировой отступ вокруг компонентов — контекст для рамки вьюпорта. */
const MINIMAP_MARGIN = 60;
/** Пиксельный отступ внутри миникарты, чтобы крайние компоненты не упирались в рамку. */
const MINIMAP_PAD = 10;

type MutableRef<T> = { current: T };

type MinimapProps = {
  components: (CircuitComponentView | null)[];
  backgroundXRef: MutableRef<number>;
  backgroundYRef: MutableRef<number>;
  zoomRef: MutableRef<number>;
  /** Основной SVG схемы — используется для замера видимой области (без transform-scale). */
  svgRef: MutableRef<SVGSVGElement | null>;
  /** Клик: центрировать вид на мировой точке. */
  onCenter: (wx: number, wy: number, zoom: number) => void;
  /** Начало перетаскивания рамки вьюпорта. */
  onPanBegin: () => void;
  /** Протяжка: сдвиг на мировую дельту (grab-and-drag панорама). */
  onPanBy: (worldDX: number, worldDY: number) => void;
  /** Завершение перетаскивания: закрепить панораму на сервере. */
  onPanCommit: () => void;
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
 * Стабильная ссылка на колбэк, вызывающий свою самую свежую версию
 * (для window add/removeEventListener в функциональном компоненте).
 */
function useStableCallback<A extends unknown[], R>(
  fn: (...args: A) => R,
): (...args: A) => R {
  const ref = useRef(fn);
  ref.current = fn;
  return useCallback((...args: A) => ref.current(...args), []);
}

/**
 * Миникарта: все узлы точками + рамка текущей видимой области. Точки/рамка — в
 * фиксированных пикселях (не зависят от масштаба мира). Обновляется собственным
 * RAF-циклом, читающим ref-координаты панорамы/зума, без перерисовки всего дерева.
 * Клик — центрировать вид; перетаскивание — grab-and-drag панорама.
 */
export const Minimap = (props: MinimapProps) => {
  const {
    components,
    backgroundXRef,
    backgroundYRef,
    zoomRef,
    svgRef,
    onCenter,
    onPanBegin,
    onPanBy,
    onPanCommit,
  } = props;

  const mapRef = useRef<HTMLDivElement | null>(null);
  const [view, setView] = useState<ViewRect | null>(null);
  const dragRef = useRef<{ wx: number; wy: number; moved: boolean } | null>(null);
  const toWorldRef = useRef<(cx: number, cy: number) => { x: number; y: number }>(
    () => ({ x: 0, y: 0 }),
  );

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
      const vw = svg ? svg.clientWidth : 0;
      const vh = svg ? svg.clientHeight : 0;
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

  const handleDragMove = useStableCallback((event: MouseEvent) => {
    const drag = dragRef.current;
    if (!drag) {
      return;
    }
    const local = toWorldRef.current(event.clientX, event.clientY);
    const dx = local.x - drag.wx;
    const dy = local.y - drag.wy;
    if (!drag.moved) {
      if (dx * dx + dy * dy < 9) {
        return;
      }
      drag.moved = true;
    }
    onPanBy(dx, dy);
  });

  const handleDragEnd = useStableCallback((event: MouseEvent) => {
    window.removeEventListener('mousemove', handleDragMove);
    window.removeEventListener('mouseup', handleDragEnd);
    const drag = dragRef.current;
    dragRef.current = null;
    if (!drag) {
      return;
    }
    if (drag.moved) {
      onPanCommit();
    }
    else {
      const local = toWorldRef.current(event.clientX, event.clientY);
      onCenter(local.x, local.y, zoomRef.current || 1);
    }
  });

  if (!world) {
    return null;
  }

  const worldW = world.maxX - world.minX;
  const worldH = world.maxY - world.minY;
  // Вписываем мир с фиксированным пиксельным отступом, чтобы крайние точки
  // не упирались в границу миникарты при большом разбросе компонентов.
  const scale = Math.min(
    (MAP_W - 2 * MINIMAP_PAD) / worldW,
    (MAP_H - 2 * MINIMAP_PAD) / worldH,
  );
  const offsetX = (MAP_W - worldW * scale) / 2;
  const offsetY = (MAP_H - worldH * scale) / 2;
  const toX = (wx: number) => offsetX + (wx - world.minX) * scale;
  const toY = (wy: number) => offsetY + (wy - world.minY) * scale;
  toWorldRef.current = (cx, cy) => {
    const el = mapRef.current;
    if (!el) {
      return { x: 0, y: 0 };
    }
    const r = el.getBoundingClientRect();
    return {
      x: world.minX + ((cx - r.left) - offsetX) / scale,
      y: world.minY + ((cy - r.top) - offsetY) / scale,
    };
  };

  const handleMouseDown = (e: ReactMouseEvent<HTMLDivElement>) => {
    if (e.button !== 0) {
      return;
    }
    e.preventDefault();
    const local = toWorldRef.current(e.clientX, e.clientY);
    dragRef.current = { wx: local.x, wy: local.y, moved: false };
    onPanBegin();
    window.addEventListener('mousemove', handleDragMove);
    window.addEventListener('mouseup', handleDragEnd);
  };

  return (
    <div
      ref={mapRef}
      className="IntegratedCircuit__minimap"
      style={{ width: MAP_W, height: MAP_H }}
      onMouseDown={handleMouseDown}>
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