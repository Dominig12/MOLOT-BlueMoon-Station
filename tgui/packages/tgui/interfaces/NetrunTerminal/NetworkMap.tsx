import { KeyboardEvent, useEffect, useRef, useState } from 'react';

import { useBackend } from '../../backend';
import { Box, Button, Icon, Input } from '../../components';
import {
  createGraphLayoutCache,
  graphAdjacency,
  graphNeighborhood,
  GraphPoint,
  layoutGraph,
} from './mapLayout';
import {
  ACCESS_COLORS,
  ACCESS_NAMES,
  NetNode,
  NetrunData,
  NODE_ICONS,
  NODE_NAMES,
  THEME,
  Waypoint,
} from './types';

type Placed = NetNode & GraphPoint;

/** Only consecutive, visible graph edges may form an overlay route. */
const routePath = (addresses: string[], points: Map<string, GraphPoint>, adjacency: Map<string, Set<string>>) => {
  let path = '';
  let previous: string | null = null;
  for (const address of addresses) {
    const point = points.get(address);
    if (!point) { previous = null; continue; }
    const from = previous && points.get(previous);
    if (from && adjacency.get(previous)?.has(address)) {
      path += `M ${from.px},${from.py} L ${point.px},${point.py} `;
    }
    previous = address;
  }
  return path;
};

/** The backend publishes the actual wiring. Coordinates are graph positions,
 * independent of station tiles, filtering and the current polling frame.
 */
export const StationMap = () => {
  const { act, data } = useBackend<NetrunData>();
  const { selected, selected_network, jack, entity, breach, map } = data;
  const canvasRef = useRef<HTMLDivElement>(null);
  const cache = useRef(createGraphLayoutCache());
  const [pan, setPan] = useState({ x: -600, y: -240 });
  const [zoom, setZoom] = useState(0.7);
  const [query, setQuery] = useState('');
  const [focusNearby, setFocusNearby] = useState(false);
  const [disabledTypes, setDisabledTypes] = useState<Record<string, boolean>>({});
  const drag = useRef<{ x: number; y: number; ox: number; oy: number } | null>(null);
  const prevBreach = useRef(false);
  useEffect(() => {
    if (prevBreach.current && !breach) {
      setQuery('');
      setDisabledTypes({});
    }
    prevBreach.current = !!breach;
  }, [breach]);

  if (!map) { return null; }
  if (!map.nodes.length) {
    return <Box p={2} color={THEME.muted}>Нет доступных узлов для подключения.</Box>;
  }
  const positions = layoutGraph(map.nodes, map.edges, cache.current);
  const adjacency = graphAdjacency(map.nodes, map.edges);
  const placed: Placed[] = map.nodes.map((node) => ({ ...node, ...positions.get(node.address) }));
  const byAddress = new Map(placed.map((node) => [node.address, node]));
  const gateways = new Map(map.gateways.map((gateway) => [gateway.id, gateway]));
  const types = [...new Set(map.nodes.map((node) => node.type))];
  const nearby = selected ? graphNeighborhood(adjacency, selected.address, 2) : new Set<string>();
  const q = query.trim().toLowerCase();
  const visible = (node: NetNode) => !disabledTypes[node.type]
    && (!focusNearby || !selected || nearby.has(node.address))
    && (!q || [node.name, node.address, NODE_NAMES[node.type] || node.type, node.sector || '']
      .some((value) => value.toLowerCase().includes(q)));
  const visibleNodes = placed.filter(visible);
  const visibleIds = new Set(visibleNodes.map((node) => node.address));
  const visiblePositions = new Map(visibleNodes.map((node) => [node.address, node]));
  const pingPath = routePath((data.ping_route ?? []).filter((hop) => hop.kind === 'node').map((hop) => hop.ref), visiblePositions, adjacency);
  const waypointPath = routePath(data.waypoint?.route ?? [], visiblePositions, adjacency);

  // LAN events may name a network, but its centroid is never a graph vertex.
  const centroids = new Map<string, { px: number; py: number; count: number }>();
  for (const node of visibleNodes) {
    if (!node.network) { continue; }
    const point = centroids.get(node.network) ?? { px: 0, py: 0, count: 0 };
    point.px += node.px; point.py += node.py; point.count++;
    centroids.set(node.network, point);
  }
  const eventPoint = (address: string | null): GraphPoint | null => {
    if (!address) { return null; }
    const node = visiblePositions.get(address);
    if (node) { return node; }
    const centroid = centroids.get(address);
    return centroid ? { px: centroid.px / centroid.count, py: centroid.py / centroid.count } : null;
  };
  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (event.target !== event.currentTarget) { return; }
    const key = event.code?.startsWith('Key') ? event.code.slice(3).toLowerCase() : event.key.toLowerCase();
    const directions: Record<string, [number, number]> = { w: [0, -1], s: [0, 1], a: [-1, 0], d: [1, 0] };
    if (!directions[key]) { return; }
    event.preventDefault(); event.stopPropagation();
    const hopping = event.shiftKey && !!entity;
    const current = byAddress.get(hopping ? entity.host : selected?.address ?? map.focus ?? map.nodes[0].address);
    if (!current) { return; }
    const [dx, dy] = directions[key];
    const liveNeighbors = new Set(map.edges.filter((edge) => edge.online !== false && (edge.from === current.address || edge.to === current.address))
      .map((edge) => edge.from === current.address ? edge.to : edge.from));
    let best: Placed | null = null;
    let bestScore = Infinity;
    for (const node of visibleNodes) {
      if (node.address === current.address) { continue; }
      if (hopping && (!liveNeighbors.has(node.address) || !node.online || node.access < 2)) { continue; }
      const vx = node.px - current.px;
      const vy = node.py - current.py;
      if (vx * dx + vy * dy <= 0) { continue; }
      const score = Math.abs(vx * dy - vy * dx) * 2 + Math.hypot(vx, vy);
      if (score < bestScore) { best = node; bestScore = score; }
    }
    if (best) { act(hopping ? 'hop' : 'select', { address: best.address }); }
  };

  return (
    <Box style={{ background: THEME.bg, border: `1px solid ${THEME.line}` }}>
      <Box p={0.5} style={{ display: 'flex', alignItems: 'center', gap: '4px', flexWrap: 'wrap' }}>
        <Input width="140px" placeholder="поиск узла…" value={query} onInput={(_event, value) => setQuery(value)} />
        <Button compact icon="bullseye" content="2 перехода" selected={focusNearby}
          disabled={!selected} tooltip="Оставить выбранный узел и его окружение по реальным связям."
          onClick={() => setFocusNearby(!focusNearby)} />
        <Button compact icon="crosshairs" tooltip="Центрировать выбранный узел" disabled={!selected}
          onClick={() => {
            const point = selected && positions.get(selected.address);
            const canvas = canvasRef.current;
            if (point && canvas) { setPan({ x: canvas.clientWidth / 2 - point.px * zoom, y: canvas.clientHeight / 2 - point.py * zoom }); }
          }} />
        <Button compact icon="expand" tooltip="Вместить видимые узлы" onClick={() => {
          const canvas = canvasRef.current;
          if (!canvas || !visibleNodes.length) { return; }
          const left = Math.min(...visibleNodes.map((node) => node.px)) - 70;
          const right = Math.max(...visibleNodes.map((node) => node.px)) + 70;
          const top = Math.min(...visibleNodes.map((node) => node.py)) - 50;
          const bottom = Math.max(...visibleNodes.map((node) => node.py)) + 50;
          const nextZoom = Math.min(2.2, Math.max(0.1, Math.min(canvas.clientWidth / (right - left), canvas.clientHeight / (bottom - top))));
          setZoom(nextZoom);
          setPan({ x: (canvas.clientWidth - (left + right) * nextZoom) / 2, y: (canvas.clientHeight - (top + bottom) * nextZoom) / 2 });
        }} />
        {types.map((type) => <Button key={type} compact icon={NODE_ICONS[type] || 'circle'}
          selected={!disabledTypes[type]} aria-label={`Фильтр: ${NODE_NAMES[type] || type}`}
          tooltip={NODE_NAMES[type] || type}
          onClick={() => setDisabledTypes((current) => ({ ...current, [type]: !current[type] }))} />)}
        <Box color={THEME.muted} fontSize="10px">
          {visibleNodes.length}/{placed.length} · глубина {map.depth} перехода · WASD — выбор{entity ? ', Shift+WASD — соседний узел' : ''} · тащите поле мышью
        </Box>
      </Box>
      <Box p={0.5} style={{ display: 'flex', gap: '4px', flexWrap: 'wrap' }}>
        {map.gateways.map((gateway) => <Button key={gateway.id} compact content={gateway.code}
          icon={gateway.has_key ? 'key' : gateway.access ? 'network-wired' : 'lock'}
          selected={selected_network?.id === gateway.id}
          tooltip={`${gateway.name} · ${ACCESS_NAMES[gateway.access]} · защита ${gateway.security}`}
          style={{ color: gateway.color }} onClick={() => act('select_network', { id: gateway.id })} />)}
        {data.waypoint && <WaypointRoute wp={data.waypoint} onClear={() => act('clear_waypoint')}
          onNext={(address) => act('select', { address })} />}
      </Box>
      <div ref={canvasRef} role="application" aria-label="Карта сети" tabIndex={0} onKeyDown={onKeyDown}
        onMouseDown={(event) => {
          if (event.button !== 0) { return; }
          event.currentTarget.focus();
          drag.current = { x: event.clientX, y: event.clientY, ox: pan.x, oy: pan.y };
        }}
        onMouseMove={(event) => {
          if (drag.current) { setPan({ x: drag.current.ox + event.clientX - drag.current.x, y: drag.current.oy + event.clientY - drag.current.y }); }
        }}
        onMouseUp={() => { drag.current = null; }} onMouseLeave={() => { drag.current = null; }}
        onWheel={(event) => {
          event.preventDefault();
          const nextZoom = Math.min(2.2, Math.max(0.1, zoom * (event.deltaY < 0 ? 1.12 : 1 / 1.12)));
          const rect = event.currentTarget.getBoundingClientRect();
          const x = event.clientX - rect.left;
          const y = event.clientY - rect.top;
          setPan({ x: x - (x - pan.x) * nextZoom / zoom, y: y - (y - pan.y) * nextZoom / zoom });
          setZoom(nextZoom);
        }}
        style={{ position: 'relative', height: '420px', minHeight: '220px', resize: 'vertical', overflow: 'hidden', cursor: 'grab', outlineOffset: '-2px' }}>
        <div style={{ position: 'absolute', width: '2000px', height: '1300px', transform: `translate(${pan.x}px, ${pan.y}px) scale(${zoom})`, transformOrigin: '0 0' }}>
          <svg width={2000} height={1300} style={{ position: 'absolute', left: 0, top: 0, pointerEvents: 'none', overflow: 'visible' }}>
            {map.edges.filter((edge) => visibleIds.has(edge.from) && visibleIds.has(edge.to)).map((edge) => {
              const from = positions.get(edge.from);
              const to = positions.get(edge.to);
              return <line key={edge.id} data-net-edge={edge.id} data-from={edge.from} data-to={edge.to} data-kind={edge.kind}
                x1={from.px} y1={from.py} x2={to.px} y2={to.py}
                stroke={edge.kind === 'relay' ? THEME.accent : edge.kind === 'apc' ? THEME.muted : THEME.line}
                strokeOpacity={edge.online === false ? 0.2 : edge.kind === 'endpoint' ? 0.65 : 0.8}
                strokeWidth={edge.kind === 'endpoint' ? 1 : 2} strokeDasharray={edge.online === false ? '3 6' : edge.kind === 'relay' ? '6 4' : undefined} />;
            })}
            {waypointPath && <path d={waypointPath} data-net-overlay="waypoint" fill="none" stroke="#d05090" strokeWidth={3} strokeDasharray="8 4" />}
            {pingPath && <g data-net-overlay="ping">
              <path d={pingPath} fill="none" stroke={THEME.warn} strokeWidth={2} strokeDasharray="4 4" />
              <circle r={4} fill={THEME.warn}><animateMotion dur="1.2s" repeatCount="indefinite" path={pingPath} /></circle>
            </g>}
            {(data.events ?? []).map((event, index) => {
              const to = eventPoint(event.to) ?? eventPoint(event.from);
              if (!to) { return null; }
              const from = eventPoint(event.from);
              const color = event.kind === 'trace' ? THEME.bad : event.kind === 'command' ? THEME.accent : THEME.warn;
              return <g key={index} opacity={Math.max(0, 1 - event.age / 4)}>
                {from && (from.px !== to.px || from.py !== to.py) && <line x1={from.px} y1={from.py} x2={to.px} y2={to.py} stroke={color} strokeOpacity={0.4} />}
                <circle cx={to.px} cy={to.py} r={6 + event.age * 7} fill="none" stroke={color} strokeWidth={2} />
              </g>;
            })}
          </svg>
          {visibleNodes.map((node) => <NodeMarker key={node.address} node={node}
            selected={selected?.address === node.address} jacked={jack?.address === node.address}
            focused={map.focus === node.address} color={gateways.get(node.network)?.color || THEME.accent}
            onClick={() => act('select', { address: node.address })} />)}
        </div>
      </div>
    </Box>
  );
};

const NodeMarker = (props: { node: Placed; selected: boolean; jacked: boolean; focused: boolean; color: string; onClick: () => void }) => {
  const { node, selected, jacked, focused, color, onClick } = props;
  return (
    <div onClick={onClick} data-net-node={node.address} title={`${node.name} ${node.address} — ${NODE_NAMES[node.type] || node.type}`}
      style={{ position: 'absolute', left: `${node.px}px`, top: `${node.py}px`, transform: 'translate(-50%, -50%)', textAlign: 'center', cursor: 'pointer', zIndex: selected ? 3 : 1 }}>
      <div style={{ position: 'relative', width: '18px', height: '18px', margin: '0 auto', borderRadius: node.type === 'apc' ? '3px' : '50%',
        background: node.online ? ACCESS_COLORS[node.access] : '#5a2a2a',
        border: `2px solid ${selected ? THEME.text : jacked ? THEME.good : focused ? THEME.accent : THEME.bg}`,
        boxShadow: node.entities > 0 ? '0 0 0 2px #d05090' : undefined }}>
        <Box style={{ position: 'absolute', left: '13px', top: '-8px', background: THEME.panel, borderRadius: '50%', width: '15px', height: '15px', lineHeight: '15px', fontSize: '9px', color }}>
          <Icon name={NODE_ICONS[node.type] || 'circle'} style={{ fontSize: '80%' }} />
        </Box>
      </div>
      <Box style={{ fontSize: '9px', fontFamily: 'monospace', color: THEME.muted, whiteSpace: 'nowrap', marginTop: '2px' }}>
        {node.name.length > 18 ? node.name.slice(0, 17) + '…' : node.name}
      </Box>
    </div>
  );
};

const WaypointRoute = (props: { wp: Waypoint; onClear: () => void; onNext: (address: string) => void }) => (
  <Box inline ml={1} color={props.wp.lost || !props.wp.reachable ? THEME.bad : THEME.accent} fontSize="10px">
    <Icon name="route" mr={0.5} />{props.wp.name} · {props.wp.lost ? 'цель потеряна' : props.wp.reachable ? `${props.wp.hops} переходов` : 'нет маршрута'}
    {props.wp.next && <Button compact ml={0.5} icon="arrow-right" content="Следующий узел" onClick={() => props.onNext(props.wp.next)} />}
    <Button compact icon="xmark" ml={0.5} onClick={props.onClear} />
  </Box>
);
