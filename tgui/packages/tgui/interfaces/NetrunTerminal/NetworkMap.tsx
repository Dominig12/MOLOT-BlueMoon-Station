import { ReactElement } from 'react';

import { useBackend } from '../../backend';
import { Box } from '../../components';
import {
  ACCESS_COLORS,
  NetNode,
  NetrunData,
  NetworkEntry,
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

/** Карта ЛВС: узлы на своих координатах станции */
export const LanMap = () => {
  const { act, data } = useBackend<NetrunData>();
  const { view, selected, jack } = data;
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
  const xs = nodes.map((n) => n.x);
  const ys = nodes.map((n) => n.y);
  const minX = Math.min(...xs);
  const maxX = Math.max(...xs);
  const minY = Math.min(...ys);
  const maxY = Math.max(...ys);
  const spanX = Math.max(maxX - minX, 1);
  const spanY = Math.max(maxY - minY, 1);
  const scale = Math.min((WIDTH - PAD * 2) / spanX, (HEIGHT - PAD * 2) / spanY);
  const offsetX = (WIDTH - spanX * scale) / 2;
  const offsetY = (HEIGHT - spanY * scale) / 2;
  // Y в BYOND растёт вверх
  const px = (n: NetNode) => offsetX + (n.x - minX) * scale;
  const py = (n: NetNode) => HEIGHT - (offsetY + (n.y - minY) * scale);
  const gx = nodes.reduce((sum, n) => sum + px(n), 0) / nodes.length;
  const gy = nodes.reduce((sum, n) => sum + py(n), 0) / nodes.length;
  return (
    <svg
      width="100%"
      viewBox={`0 0 ${WIDTH} ${HEIGHT}`}
      style={{ background: THEME.bg, display: 'block' }}
    >
      <Grid />
      {nodes.map((n) => (
        <line
          key={`l-${n.address}`}
          x1={gx}
          y1={gy}
          x2={px(n)}
          y2={py(n)}
          stroke={view.color}
          strokeOpacity={n.active ? 0.6 : 0.07}
          strokeWidth={n.active ? 1.5 : 1}
        />
      ))}
      <rect
        x={gx - 7}
        y={gy - 7}
        width={14}
        height={14}
        fill={THEME.panel}
        stroke={view.color}
        strokeWidth={2}
        transform={`rotate(45 ${gx} ${gy})`}
      />
      {nodes.map((n) => (
        <NodeDot
          key={n.address}
          node={n}
          x={px(n)}
          y={py(n)}
          selected={selected?.address === n.address}
          jacked={jack?.address === n.address}
          onClick={() => act('select', { address: n.address })}
        />
      ))}
    </svg>
  );
};

const Grid = () => {
  const lines: ReactElement[] = [];
  for (let x = 0; x <= WIDTH; x += 40) {
    lines.push(
      <line key={`gx${x}`} x1={x} y1={0} x2={x} y2={HEIGHT} stroke={THEME.line} strokeOpacity={0.35} />,
    );
  }
  for (let y = 0; y <= HEIGHT; y += 40) {
    lines.push(
      <line key={`gy${y}`} x1={0} y1={y} x2={WIDTH} y2={y} stroke={THEME.line} strokeOpacity={0.35} />,
    );
  }
  return <g>{lines}</g>;
};

const NodeDot = (props: {
  node: NetNode;
  x: number;
  y: number;
  selected: boolean;
  jacked: boolean;
  onClick: () => void;
}) => {
  const { node, x, y, selected, jacked, onClick } = props;
  const fill = node.online ? ACCESS_COLORS[node.access] : '#3a2020';
  const r = node.type === 'server' || node.type === 'terminal' ? 5 : 3.5;
  return (
    <g onClick={onClick} style={{ cursor: 'pointer' }}>
      {node.active && (
        <circle cx={x} cy={y} r={r} fill="none" stroke={THEME.warn}>
          <animate attributeName="r" from={r} to={r + 10} dur="1.2s" repeatCount="indefinite" />
          <animate attributeName="opacity" from={0.9} to={0} dur="1.2s" repeatCount="indefinite" />
        </circle>
      )}
      {node.entities > 0 && (
        <circle cx={x} cy={y} r={r + 3} fill="none" stroke="#d05090" strokeWidth={1.5} />
      )}
      {selected && (
        <circle cx={x} cy={y} r={r + 6} fill="none" stroke={THEME.text} strokeWidth={1} />
      )}
      {jacked && (
        <rect x={x - r - 4} y={y - r - 4} width={(r + 4) * 2} height={(r + 4) * 2} fill="none" stroke={THEME.good} strokeDasharray="2 2" />
      )}
      <circle cx={x} cy={y} r={r} fill={fill} stroke={THEME.bg} strokeWidth={1} />
      <title>
        {`${node.name} ${node.address}`}
      </title>
    </g>
  );
};
