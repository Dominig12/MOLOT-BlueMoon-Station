import { KeyboardEvent, useRef, useState } from 'react';

import { useBackend } from '../../backend';
import { Box, Button, Icon, Input } from '../../components';
import {
  ACCESS_COLORS,
  NetNode,
  NetrunData,
  NetworkEntry,
  NODE_ICONS,
  NODE_NAMES,
  THEME,
} from './types';

const WIDTH = 520;
const HEIGHT = 360;
const PAD = 24;

/** Обзор: NTnet в центре, локальные сети по кругу */
export const TopologyMap = () => {
  const { act, data } = useBackend<NetrunData>();
  const { networks, view, uplink } = data;
  const cx = WIDTH / 2;
  const cy = HEIGHT / 2;
  const radius = Math.min(WIDTH, HEIGHT) / 2 - 50;
  const placed = networks.map((net, i) => {
    const angle = (i / Math.max(networks.length, 1)) * Math.PI * 2 - Math.PI / 2;
    return {
      net,
      x: cx + Math.cos(angle) * radius,
      y: cy + Math.sin(angle) * radius,
    };
  });
  return (
    <svg
      width="100%"
      viewBox={`0 0 ${WIDTH} ${HEIGHT}`}
      style={{ background: THEME.bg, display: 'block' }}
    >
      <defs>
        <radialGradient id="netrun-hub">
          <stop offset="0%" stopColor={THEME.accent} stopOpacity={0.6} />
          <stop offset="100%" stopColor={THEME.accent} stopOpacity={0} />
        </radialGradient>
      </defs>
      {placed.map(({ net, x, y }) => (
        <g key={`link-${net.id}`}>
          <line
            x1={cx}
            y1={cy}
            x2={x}
            y2={y}
            stroke={net.reachable ? net.color : THEME.line}
            strokeOpacity={net.reachable ? 0.5 : 0.3}
            strokeWidth={net.isolated ? 1 : 2}
            strokeDasharray={net.isolated ? '4 4' : undefined}
          />
          {net.reachable && uplink && !net.isolated && (
            <circle r={2.5} fill={net.color}>
              <animateMotion
                dur={`${2 + net.security * 0.4}s`}
                repeatCount="indefinite"
                path={`M${cx},${cy} L${x},${y}`}
              />
            </circle>
          )}
        </g>
      ))}
      <circle cx={cx} cy={cy} r={46} fill="url(#netrun-hub)" />
      <circle
        cx={cx}
        cy={cy}
        r={22}
        fill={THEME.panel}
        stroke={uplink ? THEME.accent : THEME.bad}
        strokeWidth={2}
      />
      <text
        x={cx}
        y={cy + 4}
        textAnchor="middle"
        fill={uplink ? THEME.accent : THEME.bad}
        fontSize={11}
        fontFamily="monospace"
      >
        NTnet
      </text>
      {placed.map(({ net, x, y }) => (
        <NetworkBubble
          key={net.id}
          net={net}
          x={x}
          y={y}
          selected={view?.id === net.id}
          onClick={() => act('view_network', { id: net.id })}
        />
      ))}
    </svg>
  );
};

const NetworkBubble = (props: {
  net: NetworkEntry;
  x: number;
  y: number;
  selected: boolean;
  onClick: () => void;
}) => {
  const { net, x, y, selected, onClick } = props;
  const size = 14 + Math.min(16, Math.sqrt(net.nodes) * 1.5);
  const opened = net.access > 0;
  return (
    <g
      onClick={net.reachable ? onClick : undefined}
      style={{ cursor: net.reachable ? 'pointer' : 'default' }}
      opacity={net.reachable ? 1 : 0.4}
    >
      {selected && (
        <circle
          cx={x}
          cy={y}
          r={size + 6}
          fill="none"
          stroke={net.color}
          strokeWidth={1}
          strokeDasharray="3 3"
        />
      )}
      <circle
        cx={x}
        cy={y}
        r={size}
        fill={THEME.panel}
        stroke={net.color}
        strokeWidth={opened ? 3 : 1.5}
      />
      <text
        x={x}
        y={y + 4}
        textAnchor="middle"
        fill={net.color}
        fontSize={11}
        fontWeight="bold"
        fontFamily="monospace"
      >
        {net.short}
      </text>
      <text
        x={x}
        y={y + size + 13}
        textAnchor="middle"
        fill={THEME.muted}
        fontSize={9}
        fontFamily="monospace"
      >
        {net.nodes} уз. · защ. {net.security}
        {net.home ? ' · здесь' : ''}
      </text>
    </g>
  );
};

/** Поле узлов ЛВС: панорамирование, иконки-типы, поиск/фильтр, вложенность, WASD */
const CONTENT_W = 900;
const CONTENT_H = 560;
const MARGIN = 60;

type Placed = NetNode & { px: number; py: number };

export const LanMap = () => {
  const { act, data } = useBackend<NetrunData>();
  const { view, selected, jack, entity } = data;
  const canvasRef = useRef<HTMLDivElement>(null);
  const [pan, setPan] = useState({ x: 0, y: 0 });
  const [query, setQuery] = useState('');
  const [disabledTypes, setDisabledTypes] = useState<Record<string, boolean>>(
    {},
  );
  const [focusAddr, setFocusAddr] = useState<string | null>(null);
  const drag = useRef<{ x: number; y: number; ox: number; oy: number } | null>(
    null,
  );

  if (!view) {
    return null;
  }
  if (view.access < 1) {
    return (
      <Box
        p={2}
        textAlign="center"
        color={THEME.muted}
        style={{ background: THEME.bg, fontFamily: 'monospace' }}
      >
        Шлюз сети {view.name} закрыт. Нужен гостевой доступ.
      </Box>
    );
  }
  const nodes = view.nodes;
  if (!nodes.length) {
    return (
      <Box p={2} color={THEME.muted} style={{ background: THEME.bg }}>
        В сети нет узлов.
      </Box>
    );
  }

  // Относительные координаты станции -> поле CONTENT, Y вверх
  const xs = nodes.map((n) => n.x);
  const ys = nodes.map((n) => n.y);
  const minX = Math.min(...xs);
  const maxX = Math.max(...xs);
  const minY = Math.min(...ys);
  const maxY = Math.max(...ys);
  const spanX = Math.max(maxX - minX, 1);
  const spanY = Math.max(maxY - minY, 1);
  const scale = Math.min(
    (CONTENT_W - MARGIN * 2) / spanX,
    (CONTENT_H - MARGIN * 2) / spanY,
  );
  const offX = (CONTENT_W - spanX * scale) / 2;
  const offY = (CONTENT_H - spanY * scale) / 2;
  const placed: Placed[] = nodes.map((n) => ({
    ...n,
    px: offX + (n.x - minX) * scale,
    py: CONTENT_H - (offY + (n.y - minY) * scale),
  }));
  const byAddr: Record<string, Placed> = {};
  for (const p of placed) {
    byAddr[p.address] = p;
  }
  const cx = placed.reduce((s, p) => s + p.px, 0) / placed.length;
  const cy = placed.reduce((s, p) => s + p.py, 0) / placed.length;

  const types = Array.from(new Set(nodes.map((n) => n.type)));
  const q = query.trim().toLowerCase();
  const matches = (n: NetNode) => {
    if (disabledTypes[n.type]) {
      return false;
    }
    if (!q) {
      return true;
    }
    return (
      n.name.toLowerCase().includes(q) ||
      n.address.toLowerCase().includes(q) ||
      (NODE_NAMES[n.type] || n.type).toLowerCase().includes(q)
    );
  };

  // Набор «родственных» узлов при фокусе: сам, его аплинк, дети и соседи (до 2 вложений)
  const related = (addr: string): Set<string> => {
    const set = new Set<string>();
    const f = byAddr[addr];
    if (!f) {
      return set;
    }
    set.add(f.address);
    if (f.uplink) {
      set.add(f.uplink);
      const up = byAddr[f.uplink];
      if (up?.uplink) {
        set.add(up.uplink);
      }
    }
    for (const p of placed) {
      if (p.uplink === f.address || (f.uplink && p.uplink === f.uplink)) {
        set.add(p.address);
      }
    }
    return set;
  };
  const focusSet = focusAddr ? related(focusAddr) : null;

  const visible = (n: NetNode) =>
    matches(n) && (!focusSet || focusSet.has(n.address));

  const onKeyDown = (e: KeyboardEvent<HTMLDivElement>) => {
    const key = e.key.toLowerCase();
    const dirs: Record<string, [number, number]> = {
      w: [0, 1],
      s: [0, -1],
      a: [-1, 0],
      d: [1, 0],
    };
    if (!dirs[key]) {
      return;
    }
    e.preventDefault();
    const [dx, dy] = dirs[key];
    const cur = selected ? byAddr[selected.address] : placed[0];
    if (!cur) {
      return;
    }
    let best: Placed | null = null;
    let bestScore = Infinity;
    for (const p of placed) {
      if (p.address === cur.address || !visible(p)) {
        continue;
      }
      const vx = p.x - cur.x;
      const vy = p.y - cur.y;
      const along = vx * dx + vy * dy;
      if (along <= 0) {
        continue;
      }
      const off = Math.abs(vx * dy + vy * dx);
      const score = off * 2 + Math.hypot(vx, vy);
      if (score < bestScore) {
        bestScore = score;
        best = p;
      }
    }
    if (!best) {
      return;
    }
    if (e.shiftKey && entity) {
      act('hop', { address: best.address });
    } else {
      act('select', { address: best.address });
    }
  };

  return (
    <Box style={{ background: THEME.bg, border: `1px solid ${THEME.line}` }}>
      <Box
        p={0.5}
        style={{ display: 'flex', alignItems: 'center', gap: '4px', flexWrap: 'wrap' }}
      >
        <Box inline bold style={{ fontFamily: 'monospace', color: view.color }}>
          {view.code}
        </Box>
        <Input
          width="130px"
          placeholder="поиск узла…"
          value={query}
          onInput={(_e, v) => setQuery(v)}
        />
        {types.map((t) => (
          <Button
            key={t}
            compact
            icon={NODE_ICONS[t] || 'circle'}
            selected={!disabledTypes[t]}
            tooltip={NODE_NAMES[t] || t}
            onClick={() =>
              setDisabledTypes({ ...disabledTypes, [t]: !disabledTypes[t] })
            }
          />
        ))}
        {focusAddr && (
          <Button
            compact
            icon="expand"
            content="вся сеть"
            onClick={() => setFocusAddr(null)}
          />
        )}
        <Box inline color={THEME.muted} fontSize="10px">
          WASD — переход{entity ? ', Shift+WASD — прыжок' : ''}
        </Box>
      </Box>
      <div
        ref={canvasRef}
        tabIndex={0}
        onKeyDown={onKeyDown}
        onMouseDown={(e) => {
          drag.current = { x: e.clientX, y: e.clientY, ox: pan.x, oy: pan.y };
        }}
        onMouseMove={(e) => {
          if (!drag.current) {
            return;
          }
          setPan({
            x: drag.current.ox + (e.clientX - drag.current.x),
            y: drag.current.oy + (e.clientY - drag.current.y),
          });
        }}
        onMouseUp={() => {
          drag.current = null;
        }}
        onMouseLeave={() => {
          drag.current = null;
        }}
        style={{
          position: 'relative',
          height: '320px',
          overflow: 'hidden',
          cursor: 'grab',
          outline: 'none',
        }}
      >
        <div
          style={{
            position: 'absolute',
            transform: `translate(${pan.x}px, ${pan.y}px)`,
            width: `${CONTENT_W}px`,
            height: `${CONTENT_H}px`,
          }}
        >
          <svg
            width={CONTENT_W}
            height={CONTENT_H}
            style={{ position: 'absolute', left: 0, top: 0, pointerEvents: 'none' }}
          >
            <rect
              x={cx - 8}
              y={cy - 8}
              width={16}
              height={16}
              fill={THEME.panel}
              stroke={view.color}
              strokeWidth={2}
              transform={`rotate(45 ${cx} ${cy})`}
            />
            {placed.map((p) => {
              if (!visible(p)) {
                return null;
              }
              const target = p.uplink && byAddr[p.uplink] ? byAddr[p.uplink] : null;
              const tx = target ? target.px : cx;
              const ty = target ? target.py : cy;
              return (
                <line
                  key={`e-${p.address}`}
                  x1={p.px}
                  y1={p.py}
                  x2={tx}
                  y2={ty}
                  stroke={view.color}
                  strokeOpacity={p.active ? 0.6 : 0.2}
                  strokeWidth={p.active ? 1.5 : 1}
                />
              );
            })}
          </svg>
          {placed.map((p) => (
            <NodeMarker
              key={p.address}
              node={p}
              dim={!visible(p)}
              selected={selected?.address === p.address}
              jacked={jack?.address === p.address}
              color={view.color}
              onClick={() => {
                act('select', { address: p.address });
                setFocusAddr(p.address);
              }}
            />
          ))}
        </div>
      </div>
    </Box>
  );
};

const NodeMarker = (props: {
  node: Placed;
  dim: boolean;
  selected: boolean;
  jacked: boolean;
  color: string;
  onClick: () => void;
}) => {
  const { node, dim, selected, jacked, color, onClick } = props;
  const fill = node.online ? ACCESS_COLORS[node.access] : '#5a2a2a';
  return (
    <div
      onClick={onClick}
      title={`${node.name} ${node.address} — ${NODE_NAMES[node.type] || node.type}`}
      style={{
        position: 'absolute',
        left: `${node.px}px`,
        top: `${node.py}px`,
        transform: 'translate(-50%, -50%)',
        textAlign: 'center',
        cursor: 'pointer',
        opacity: dim ? 0.25 : 1,
        zIndex: selected ? 3 : 1,
      }}
    >
      <div
        style={{
          position: 'relative',
          width: '16px',
          height: '16px',
          margin: '0 auto',
          borderRadius: '50%',
          background: fill,
          border: `2px solid ${selected ? THEME.text : jacked ? THEME.good : THEME.bg}`,
          boxShadow: node.entities > 0 ? '0 0 0 2px #d05090' : undefined,
        }}
      >
        <Box
          style={{
            position: 'absolute',
            left: '12px',
            top: '-6px',
            background: THEME.panel,
            borderRadius: '50%',
            width: '12px',
            height: '12px',
            lineHeight: '12px',
            fontSize: '8px',
            color: color,
          }}
        >
          <Icon name={NODE_ICONS[node.type] || 'circle'} size={0.7} />
        </Box>
      </div>
      <Box
        style={{
          fontSize: '9px',
          fontFamily: 'monospace',
          color: THEME.muted,
          whiteSpace: 'nowrap',
          marginTop: '1px',
        }}
      >
        {node.name.length > 14 ? node.name.slice(0, 13) + '…' : node.name}
      </Box>
    </div>
  );
};
