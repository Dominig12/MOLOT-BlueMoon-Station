import { KeyboardEvent, useEffect, useRef, useState } from 'react';

import { useBackend } from '../../backend';
import { Box, Button, Icon, Input } from '../../components';
import {
  ACCESS_COLORS,
  Gateway,
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

/** Единое поле всей сети: гейтвеи подсетей, APC-подузлы и машины, с иконками-типами,
 * панорамированием, поиском/фильтром, вложенностью и WASD-навигацией. */
const FIELD_W = 2000;
const FIELD_H = 1300;
const FIELD_MARGIN = 80;
const MIN_GAP = 68;

type Placed = NetNode & { px: number; py: number };
type GwPos = { id: string; gx: number; gy: number };

const spread = (nodes: Placed[]) => {
  // Несколько проходов расталкивания, чтобы узлы не накладывались
  for (let iter = 0; iter < 60; iter++) {
    let moved = false;
    for (let i = 0; i < nodes.length; i++) {
      for (let j = i + 1; j < nodes.length; j++) {
        const a = nodes[i];
        const b = nodes[j];
        let dx = b.px - a.px;
        let dy = b.py - a.py;
        let dist = Math.hypot(dx, dy);
        if (dist < 0.01) {
          dx = Math.random() - 0.5;
          dy = Math.random() - 0.5;
          dist = 0.5;
        }
        if (dist < MIN_GAP) {
          const push = (MIN_GAP - dist) / 2;
          const ux = dx / dist;
          const uy = dy / dist;
          a.px -= ux * push;
          a.py -= uy * push;
          b.px += ux * push;
          b.py += uy * push;
          moved = true;
        }
      }
    }
    if (!moved) {
      break;
    }
  }
};

export const StationMap = () => {
  const { act, data } = useBackend<NetrunData>();
  const { selected, selected_network, jack, entity, breach } = data;
  const route = data.ping_route;
  const map = data.map;
  const canvasRef = useRef<HTMLDivElement>(null);
  const [pan, setPan] = useState({ x: -600, y: -360 });
  const [zoom, setZoom] = useState(0.7);
  const [query, setQuery] = useState('');
  const [disabledTypes, setDisabledTypes] = useState<Record<string, boolean>>(
    {},
  );
  const drag = useRef<{ x: number; y: number; ox: number; oy: number } | null>(
    null,
  );
  // Сброс фильтров после завершения взлома
  const prevBreach = useRef(false);
  useEffect(() => {
    const now = !!breach;
    if (prevBreach.current && !now) {
      setQuery('');
      setDisabledTypes({});
    }
    prevBreach.current = now;
  }, [breach]);

  if (!map) {
    return null;
  }
  const nodes = map.nodes;
  if (!nodes.length && !map.gateways.length) {
    return (
      <Box p={2} color={THEME.muted} style={{ background: THEME.bg }}>
        Сеть недоступна.
      </Box>
    );
  }

  const xs = nodes.map((n) => n.x);
  const ys = nodes.map((n) => n.y);
  const minX = xs.length ? Math.min(...xs) : 0;
  const maxX = xs.length ? Math.max(...xs) : 1;
  const minY = ys.length ? Math.min(...ys) : 0;
  const maxY = ys.length ? Math.max(...ys) : 1;
  const spanX = Math.max(maxX - minX, 1);
  const spanY = Math.max(maxY - minY, 1);
  const scale = Math.min(
    (FIELD_W - FIELD_MARGIN * 2) / spanX,
    (FIELD_H - FIELD_MARGIN * 2) / spanY,
  );
  const offX = (FIELD_W - spanX * scale) / 2;
  const offY = (FIELD_H - spanY * scale) / 2;
  const placed: Placed[] = nodes.map((n) => ({
    ...n,
    px: offX + (n.x - minX) * scale,
    py: FIELD_H - (offY + (n.y - minY) * scale),
  }));
  spread(placed);
  const byAddr: Record<string, Placed> = {};
  for (const p of placed) {
    byAddr[p.address] = p;
  }

  // Позиция гейтвея = центр его узлов (или по кольцу, если узлов нет)
  const gwPos: Record<string, GwPos> = {};
  map.gateways.forEach((gw, i) => {
    const own = placed.filter((p) => p.network === gw.id);
    if (own.length) {
      gwPos[gw.id] = {
        id: gw.id,
        gx: own.reduce((s, p) => s + p.px, 0) / own.length,
        gy: own.reduce((s, p) => s + p.py, 0) / own.length - 40,
      };
    } else {
      const ang = (i / Math.max(map.gateways.length, 1)) * Math.PI * 2;
      gwPos[gw.id] = {
        id: gw.id,
        gx: FIELD_W / 2 + Math.cos(ang) * 200,
        gy: FIELD_H / 2 + Math.sin(ang) * 200,
      };
    }
  });
  const hubX = FIELD_W / 2;
  const hubY = FIELD_H / 2;

  const types = Array.from(new Set(nodes.map((n) => n.type)));
  const q = query.trim().toLowerCase();
  const visible = (n: NetNode) => {
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
      const vx = p.px - cur.px;
      const vy = -(p.py - cur.py);
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
        <Input
          width="140px"
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
        <Box inline color={THEME.muted} fontSize="10px">
          тащите поле мышью · WASD — переход{entity ? ', Shift+WASD — прыжок' : ''}
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
        onWheel={(e) => {
          e.preventDefault();
          const factor = e.deltaY < 0 ? 1.12 : 1 / 1.12;
          setZoom((z) => Math.min(2.2, Math.max(0.3, z * factor)));
        }}
        style={{
          position: 'relative',
          height: '360px',
          overflow: 'hidden',
          cursor: 'grab',
          outline: 'none',
        }}
      >
        <div
          style={{
            position: 'absolute',
            transform: `translate(${pan.x}px, ${pan.y}px) scale(${zoom})`,
            transformOrigin: '0 0',
            width: `${FIELD_W}px`,
            height: `${FIELD_H}px`,
          }}
        >
          <svg
            width={FIELD_W}
            height={FIELD_H}
            style={{ position: 'absolute', left: 0, top: 0, pointerEvents: 'none' }}
          >
            {/* гейтвей -> хаб */}
            {map.gateways.map((gw) => {
              const g = gwPos[gw.id];
              return (
                <line
                  key={`gh-${gw.id}`}
                  x1={g.gx}
                  y1={g.gy}
                  x2={hubX}
                  y2={hubY}
                  stroke={gw.color}
                  strokeOpacity={gw.access > 0 ? 0.5 : 0.2}
                  strokeWidth={gw.access > 0 ? 2 : 1}
                  strokeDasharray={gw.access > 0 ? undefined : '5 5'}
                />
              );
            })}
            {/* узел -> аплинк (APC) или -> гейтвей */}
            {placed.map((p) => {
              if (!visible(p)) {
                return null;
              }
              const up = p.uplink && byAddr[p.uplink] ? byAddr[p.uplink] : null;
              const g = p.network ? gwPos[p.network] : null;
              const tx = up ? up.px : g ? g.gx : hubX;
              const ty = up ? up.py : g ? g.gy : hubY;
              return (
                <line
                  key={`e-${p.address}`}
                  x1={p.px}
                  y1={p.py}
                  x2={tx}
                  y2={ty}
                  stroke={THEME.line}
                  strokeOpacity={p.active ? 0.5 : 0.18}
                  strokeWidth={p.active ? 1.5 : 1}
                />
              );
            })}
            {/* хаб NTnet */}
            <circle
              cx={hubX}
              cy={hubY}
              r={16}
              fill={THEME.panel}
              stroke={THEME.accent}
              strokeWidth={2}
            />
            <text
              x={hubX}
              y={hubY + 4}
              textAnchor="middle"
              fill={THEME.accent}
              fontSize={10}
              fontFamily="monospace"
            >
              NTnet
            </text>
            {route &&
              (() => {
                const pts = route
                  .map((h) => {
                    if (h.kind === 'hub') {
                      return { x: hubX, y: hubY };
                    }
                    if (h.kind === 'gateway') {
                      const g = h.ref ? gwPos[h.ref] : null;
                      return g ? { x: g.gx, y: g.gy } : null;
                    }
                    const n = h.ref ? byAddr[h.ref] : null;
                    return n ? { x: n.px, y: n.py } : null;
                  })
                  .filter((p): p is { x: number; y: number } => !!p);
                if (pts.length < 2) {
                  return null;
                }
                const d =
                  `M ${pts[0].x} ${pts[0].y} ` +
                  pts
                    .slice(1)
                    .map((p) => `L ${p.x} ${p.y}`)
                    .join(' ');
                return (
                  <g>
                    <path
                      d={d}
                      fill="none"
                      stroke={THEME.warn}
                      strokeWidth={2}
                      strokeDasharray="4 4"
                      opacity={0.9}
                    />
                    <circle r={4} fill={THEME.warn}>
                      <animateMotion dur="1.2s" repeatCount="indefinite" path={d} />
                    </circle>
                  </g>
                );
              })()}
          </svg>
          {map.gateways.map((gw) => (
            <GatewayMarker
              key={gw.id}
              gw={gw}
              pos={gwPos[gw.id]}
              selected={selected_network?.id === gw.id}
              onClick={() => act('select_network', { id: gw.id })}
            />
          ))}
          {placed.map((p) => (
            <NodeMarker
              key={p.address}
              node={p}
              dim={!visible(p)}
              selected={selected?.address === p.address}
              jacked={jack?.address === p.address}
              color={
                map.gateways.find((g) => g.id === p.network)?.color || THEME.accent
              }
              onClick={() => act('select', { address: p.address })}
            />
          ))}
        </div>
      </div>
    </Box>
  );
};

const GatewayMarker = (props: {
  gw: Gateway;
  pos: GwPos;
  selected: boolean;
  onClick: () => void;
}) => {
  const { gw, pos, selected, onClick } = props;
  const open = gw.access > 0;
  return (
    <div
      onClick={onClick}
      title={`${gw.name} — защита ${gw.security}`}
      style={{
        position: 'absolute',
        left: `${pos.gx}px`,
        top: `${pos.gy}px`,
        transform: 'translate(-50%, -50%)',
        textAlign: 'center',
        cursor: 'pointer',
        zIndex: 4,
      }}
    >
      <div
        style={{
          width: '20px',
          height: '20px',
          margin: '0 auto',
          background: THEME.panel,
          border: `2px solid ${gw.color}`,
          transform: 'rotate(45deg)',
          boxShadow: selected ? `0 0 0 3px ${gw.color}` : undefined,
          opacity: open ? 1 : 0.6,
        }}
      />
      <Box
        style={{
          fontFamily: 'monospace',
          fontSize: '10px',
          color: gw.color,
          whiteSpace: 'nowrap',
          marginTop: '2px',
        }}
      >
        {gw.code}
        {!open && <Icon name="lock" ml={0.5} />}
        {gw.has_key && <Icon name="key" ml={0.5} color={THEME.good} />}
      </Box>
    </div>
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
        opacity: dim ? 0.2 : 1,
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
            width: '13px',
            height: '13px',
            lineHeight: '13px',
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
