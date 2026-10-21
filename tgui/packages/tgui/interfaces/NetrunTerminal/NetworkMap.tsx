import { KeyboardEvent, memo, useCallback, useEffect, useMemo, useRef, useState } from 'react';

import { useBackend } from '../../backend';
import { Box, Button, Icon, Input } from '../../components';
import {
  createGraphLayoutCache,
  graphAdjacency,
  graphBounds,
  graphNeighborhood,
  GraphPoint,
  layoutGraph,
} from './mapLayout';
import {
  ACCESS_COLORS,
  ACCESS_NAMES,
  Gateway,
  NetEdge,
  NetEvent,
  NetMap,
  NetNode,
  NetrunData,
  NODE_ICONS,
  NODE_NAMES,
  PingHop,
  THEME,
  Waypoint,
} from './types';

type Placed = NetNode & GraphPoint;
type Act = (action: string, payload?: object) => void;
type MapInput = {
  map: NetMap | null;
  selectedAddress: string | null;
  selectedNetwork: string | null;
  jackAddress: string | null;
  entityHost: string | null;
  hasEntity: boolean;
  pingRoute: PingHop[];
  events: NetEvent[];
  waypoint: Waypoint | null;
};

const EMPTY_NODES: NetNode[] = [];
const EMPTY_EDGES: NetEdge[] = [];
const EMPTY_EVENTS: NetEvent[] = [];
const EMPTY_HOPS: PingHop[] = [];

// Backend payload objects are recreated even when only a log or breach cell
// changed. Retain snapshots by the fields that the map actually displays.
const useSemanticValue = <T, >(value: T, signature: string): T => {
  const snapshot = useRef({ signature, value });
  if (snapshot.current.signature !== signature) { snapshot.current = { signature, value }; }
  return snapshot.current.value;
};

export const StationMap = (props: { suspended?: boolean } = {}) => {
  const { act, data } = useBackend<NetrunData>();
  const lastInput = useRef<MapInput | null>(null);
  const breachSeen = useRef(false);
  const resetKey = useRef(0);
  if (props.suspended) {
    if (data.breach) { breachSeen.current = true; }
  } else {
    if (breachSeen.current) { resetKey.current++; breachSeen.current = false; }
    lastInput.current = {
      map: data.map, selectedAddress: data.selected?.address ?? null,
      selectedNetwork: data.selected_network?.id ?? null, jackAddress: data.jack?.address ?? null,
      entityHost: data.entity?.host ?? null, hasEntity: !!data.entity,
      pingRoute: data.ping_route ?? EMPTY_HOPS, events: data.events ?? EMPTY_EVENTS,
      waypoint: data.waypoint ?? null,
    };
  }
  // Freeze before computing signatures too: hidden maps do no graph work.
  return lastInput.current ? <MapSnapshot input={lastInput.current} act={act} resetKey={resetKey.current} /> : null;
};

const MapSnapshot = memo((props: { input: MapInput; act: Act; resetKey: number }) => {
  const { input } = props;
  const rawNodes = input.map?.nodes ?? EMPTY_NODES;
  const rawEdges = input.map?.edges ?? EMPTY_EDGES;
  const topologyKey = JSON.stringify([
    rawNodes.map((node) => [node.address, node.type, node.uplink]),
    rawEdges.map((edge) => [edge.id, edge.from, edge.to, edge.kind]),
  ]);
  const nodes = useSemanticValue(rawNodes, JSON.stringify(rawNodes.map((node) => [
    node.address, node.type, node.uplink, node.name, node.network, node.sector,
    node.online, node.access, node.entities, node.can_hop,
  ])));
  const edges = useSemanticValue(rawEdges, JSON.stringify(rawEdges));
  const gateways = useSemanticValue(input.map?.gateways ?? [], JSON.stringify(input.map?.gateways ?? []));
  const storedRoute = useSemanticValue(input.map?.route ?? null, JSON.stringify(input.map?.route ?? null));
  const map = useMemo(() => input.map ? { ...input.map, nodes, edges, gateways, route: storedRoute } : null,
    [!!input.map, input.map?.focus, input.map?.depth, nodes, edges, gateways, storedRoute]);
  const pingRoute = useSemanticValue(input.pingRoute, JSON.stringify(input.pingRoute));
  const events = useSemanticValue(input.events, JSON.stringify(input.events));
  const waypoint = useSemanticValue(input.waypoint, JSON.stringify(input.waypoint));
  return (<GraphMap {...input} map={map} pingRoute={pingRoute} events={events} waypoint={waypoint}
    topologyKey={topologyKey} act={props.act} resetKey={props.resetKey} />);
});

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
const GraphMap = memo((props: MapInput & { topologyKey: string; act: Act; resetKey: number }) => {
  const { act, selectedAddress, selectedNetwork, jackAddress, entityHost, hasEntity, map, topologyKey, pingRoute, events, waypoint, resetKey } = props;
  const canvasRef = useRef<HTMLDivElement>(null);
  const [layoutCache] = useState(createGraphLayoutCache);
  const [pan, setPan] = useState({ x: -600, y: -240 });
  const [zoom, setZoom] = useState(0.7);
  const [query, setQuery] = useState('');
  const [focusNearby, setFocusNearby] = useState(false);
  const [disabledTypes, setDisabledTypes] = useState<Record<string, boolean>>({});
  const drag = useRef<{ x: number; y: number; ox: number; oy: number } | null>(null);
  useEffect(() => {
    if (resetKey > 0) {
      setQuery('');
      setDisabledTypes({});
    }
  }, [resetKey]);
  const nodes = map?.nodes ?? EMPTY_NODES;
  const edges = map?.edges ?? EMPTY_EDGES;
  const positions = useMemo(() => layoutGraph(nodes, edges, layoutCache), [topologyKey, layoutCache]);
  const bounds = useMemo(() => graphBounds(positions.values()), [positions]);
  const adjacency = useMemo(() => graphAdjacency(nodes, edges), [topologyKey]);
  const liveAdjacency = useMemo(() => graphAdjacency(nodes, edges.filter((edge) => edge.online !== false)), [topologyKey, edges]);
  const placed = useMemo<Placed[]>(() => nodes.map((node) => ({ ...node, ...positions.get(node.address) })), [nodes, positions]);
  const byAddress = useMemo(() => new Map(placed.map((node) => [node.address, node])), [placed]);
  const gateways = useMemo(() => new Map((map?.gateways ?? []).map((gateway) => [gateway.id, gateway])), [map?.gateways]);
  const types = useMemo(() => [...new Set(nodes.map((node) => node.type))], [nodes]);
  const nearby = useMemo(() => focusNearby && selectedAddress ? graphNeighborhood(adjacency, selectedAddress, 2) : null,
    [focusNearby, selectedAddress, adjacency]);
  const q = query.trim().toLowerCase();
  const visibleNodes = useMemo(() => placed.filter((node) => !disabledTypes[node.type]
    && (!nearby || nearby.has(node.address))
    && (!q || [node.name, node.address, NODE_NAMES[node.type] || node.type, node.sector || '']
      .some((value) => value.toLowerCase().includes(q)))), [placed, disabledTypes, nearby, q]);
  const visibleKey = useMemo(() => visibleNodes.map((node) => node.address).join('\0'), [visibleNodes]);
  const visibleIds = useMemo(() => new Set(visibleNodes.map((node) => node.address)), [visibleKey]);
  const visiblePositions = useMemo(() => new Map(visibleNodes.map((node) => [node.address, positions.get(node.address)])), [visibleKey, positions]);
  const pingPath = useMemo(() => routePath(pingRoute.filter((hop) => hop.kind === 'node').map((hop) => hop.ref), visiblePositions, adjacency), [pingRoute, visiblePositions, adjacency]);
  const waypointPath = useMemo(() => routePath(waypoint?.route ?? [], visiblePositions, adjacency), [waypoint?.route, visiblePositions, adjacency]);
  const selectedPath = useMemo(() => map?.route?.reachable ? routePath(map.route.route, visiblePositions, adjacency) : '', [map?.route, visiblePositions, adjacency]);
  const onSelect = useCallback((address: string) => act('select', { address }), [act]);

  // LAN events may name a network, but its centroid is never a graph vertex.
  const centroids = useMemo(() => {
    const groups = new Map<string, { px: number; py: number; count: number }>();
    for (const node of visibleNodes) {
      if (!node.network) { continue; }
      const point = groups.get(node.network) ?? { px: 0, py: 0, count: 0 };
      point.px += node.px; point.py += node.py; point.count++;
      groups.set(node.network, point);
    }
    return new Map([...groups].map(([id, point]) => [id, { px: point.px / point.count, py: point.py / point.count }]));
  }, [visibleNodes]);
  if (!map) { return null; }
  if (!nodes.length) { return <Box p={2} color={THEME.muted}>Нет доступных узлов для подключения.</Box>; }
  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (event.target !== event.currentTarget) { return; }
    const key = event.code?.startsWith('Key') ? event.code.slice(3).toLowerCase() : event.key.toLowerCase();
    const directions: Record<string, [number, number]> = { w: [0, -1], s: [0, 1], a: [-1, 0], d: [1, 0] };
    if (!directions[key]) { return; }
    event.preventDefault(); event.stopPropagation();
    const hopping = event.shiftKey && hasEntity;
    const current = byAddress.get(hopping ? entityHost : selectedAddress ?? map.focus ?? nodes[0].address);
    if (!current) { return; }
    const [dx, dy] = directions[key];
    const liveNeighbors = liveAdjacency.get(current.address);
    let best: Placed | null = null;
    let bestScore = Infinity;
    for (const node of visibleNodes) {
      if (node.address === current.address) { continue; }
      const canHop = node.can_hop ?? (node.online && node.access >= 2);
      if (hopping && (!liveNeighbors?.has(node.address) || !canHop)) { continue; }
      const vx = node.px - current.px;
      const vy = node.py - current.py;
      if (vx * dx + vy * dy <= 0) { continue; }
      const score = Math.abs(vx * dy - vy * dx) * 2 + Math.hypot(vx, vy);
      if (score < bestScore) { best = node; bestScore = score; }
    }
    if (best) { act(hopping ? 'hop' : 'select', { address: best.address }); }
  };

  return (
    <Box data-net-layout="map" style={{ background: THEME.bg, border: `1px solid ${THEME.line}`, display: 'flex', flexDirection: 'column', height: '100%', minHeight: 0, minWidth: 0, boxSizing: 'border-box' }}>
      <Box p={0.5} style={{ display: 'flex', alignItems: 'center', gap: '4px', flexWrap: 'wrap' }}>
        <Input width="140px" placeholder="поиск узла…" value={query} onInput={(_event, value) => setQuery(value)} />
        <Button compact icon="bullseye" content="2 перехода" selected={focusNearby}
          disabled={!selectedAddress} tooltip="Оставить выбранный узел и его окружение по реальным связям."
          onClick={() => setFocusNearby(!focusNearby)} />
        <Button compact icon="crosshairs" tooltip="Центрировать выбранный узел" disabled={!selectedAddress}
          onClick={() => {
            const point = selectedAddress && positions.get(selectedAddress);
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
        {types.map((type) => (<Button key={type} compact icon={NODE_ICONS[type] || 'circle'}
          selected={!disabledTypes[type]} aria-label={`Фильтр: ${NODE_NAMES[type] || type}`}
          tooltip={NODE_NAMES[type] || type}
          onClick={() => setDisabledTypes((current) => ({ ...current, [type]: !current[type] }))} />))}
        <Box color={THEME.muted} fontSize="10px">
          {visibleNodes.length}/{placed.length} · глубина {map.depth} перехода · WASD — выбор{hasEntity ? ', Shift+WASD — соседний узел' : ''} · тащите поле мышью
        </Box>
        {map.route && <StoredRouteStatus route={map.route} />}
      </Box>
      <Box p={0.5} style={{ display: 'flex', gap: '4px', flexWrap: 'wrap' }}>
        {map.gateways.map((gateway) => (<Button key={gateway.id} compact content={gateway.code}
          icon={gateway.has_key ? 'key' : gateway.access ? 'network-wired' : 'lock'}
          selected={selectedNetwork === gateway.id}
          tooltip={`${gateway.name} · ${ACCESS_NAMES[gateway.access]} · защита ${gateway.security}`}
          style={{ color: gateway.color }} onClick={() => act('select_network', { id: gateway.id })} />))}
        {waypoint && <WaypointRoute wp={waypoint} onClear={() => act('clear_waypoint')}
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
        style={{ position: 'relative', flex: '1 1 auto', minHeight: '120px', overflow: 'hidden', cursor: 'grab', outlineOffset: '-2px' }}>
        <div data-net-world style={{ position: 'absolute', left: 0, top: 0, width: `${bounds.width}px`, height: `${bounds.height}px`, transform: `translate(${pan.x}px, ${pan.y}px) scale(${zoom})`, transformOrigin: '0 0' }}>
          <div data-net-canvas style={{ position: 'absolute', left: `${bounds.minX}px`, top: `${bounds.minY}px`, width: `${bounds.width}px`, height: `${bounds.height}px` }}>
          <svg width={bounds.width} height={bounds.height} viewBox={`${bounds.minX} ${bounds.minY} ${bounds.width} ${bounds.height}`} style={{ position: 'absolute', left: 0, top: 0, pointerEvents: 'none' }}>
            <EdgesLayer edges={edges} positions={positions} visible={visibleIds} />
            <RoutesLayer selectedPath={selectedPath} pingPath={pingPath} waypointPath={waypointPath} />
            <EventsLayer events={events} positions={visiblePositions} centroids={centroids} />
          </svg>
          <NodesLayer nodes={visibleNodes} selected={selectedAddress} jacked={jackAddress} focus={map.focus} gateways={gateways} onSelect={onSelect} originX={bounds.minX} originY={bounds.minY} />
          </div>
        </div>
      </div>
    </Box>
  );
});

const EdgesLayer = memo((props: { edges: NetEdge[]; positions: Map<string, GraphPoint>; visible: Set<string> }) => (
  <g>{props.edges.filter((edge) => props.visible.has(edge.from) && props.visible.has(edge.to)).map((edge) => {
    const from = props.positions.get(edge.from);
    const to = props.positions.get(edge.to);
    return (<line key={edge.id} data-net-edge={edge.id} data-from={edge.from} data-to={edge.to} data-kind={edge.kind}
      x1={from.px} y1={from.py} x2={to.px} y2={to.py}
      stroke={edge.kind === 'relay' ? THEME.accent : edge.kind === 'apc' ? THEME.muted : THEME.line}
      strokeOpacity={edge.online === false ? 0.2 : edge.kind === 'endpoint' ? 0.65 : 0.8}
      strokeWidth={edge.kind === 'endpoint' ? 1 : 2} strokeDasharray={edge.online === false ? '3 6' : edge.kind === 'relay' ? '6 4' : undefined} />);
  })}
  </g>
));

const RoutesLayer = memo((props: { selectedPath: string; pingPath: string; waypointPath: string }) => (
  <g>
    {props.selectedPath && <path d={props.selectedPath} data-net-overlay="selected-route" fill="none" stroke={THEME.accent} strokeWidth={3} opacity={0.7} />}
    {props.waypointPath && <path d={props.waypointPath} data-net-overlay="waypoint" fill="none" stroke="#d05090" strokeWidth={3} strokeDasharray="8 4" />}
    {props.pingPath && <g data-net-overlay="ping">
      <path d={props.pingPath} fill="none" stroke={THEME.warn} strokeWidth={2} strokeDasharray="4 4" />
      <circle r={4} fill={THEME.warn}><animateMotion dur="1.2s" repeatCount="indefinite" path={props.pingPath} /></circle>
                       </g>}
  </g>
));

const StoredRouteStatus = memo((props: { route: NonNullable<NetMap['route']> }) => (
  <Box color={props.route.reachable ? THEME.accent : THEME.bad} fontSize="10px"
    title={`Сохранённый маршрут #${props.route.revision}`}>
    {props.route.reachable ? `Путь: ${props.route.hops} пер. · ${Math.round(props.route.latency)} мс` : 'Путь: нет связи'}
  </Box>
));

const EventsLayer = memo((props: { events: NetEvent[]; positions: Map<string, GraphPoint>; centroids: Map<string, GraphPoint> }) => {
  const point = (address: string | null) => address ? props.positions.get(address) ?? props.centroids.get(address) : null;
  return (<g>{props.events.map((event, index) => {
    const to = point(event.to) ?? point(event.from);
    if (!to) { return null; }
    const from = point(event.from);
    const color = event.kind === 'trace' ? THEME.bad : event.kind === 'command' ? THEME.accent : THEME.warn;
    return (<g key={index} opacity={Math.max(0, 1 - event.age / 4)}>
      {from && (from.px !== to.px || from.py !== to.py) && <line x1={from.px} y1={from.py} x2={to.px} y2={to.py} stroke={color} strokeOpacity={0.4} />}
      <circle cx={to.px} cy={to.py} r={6 + event.age * 7} fill="none" stroke={color} strokeWidth={2} />
            </g>);
  })}
          </g>);
});

const NodesLayer = memo((props: {
  nodes: Placed[]; selected: string | null; jacked: string | null; focus: string | null;
  gateways: Map<string, Gateway>; onSelect: (address: string) => void;
  originX: number; originY: number;
}) => (<>{props.nodes.map((node) => (<NodeMarker key={node.address} node={node}
  selected={props.selected === node.address} jacked={props.jacked === node.address}
  focused={props.focus === node.address} color={props.gateways.get(node.network)?.color || THEME.accent}
  onSelect={props.onSelect} originX={props.originX} originY={props.originY} />))}
       </>));

const NodeMarker = memo((props: { node: Placed; selected: boolean; jacked: boolean; focused: boolean; color: string; onSelect: (address: string) => void; originX: number; originY: number }) => {
  const { node, selected, jacked, focused, color, onSelect } = props;
  return (
    <div onClick={() => onSelect(node.address)} data-net-node={node.address} title={`${node.name} ${node.address} — ${NODE_NAMES[node.type] || node.type}`}
      style={{ position: 'absolute', left: `${node.px - props.originX}px`, top: `${node.py - props.originY}px`, transform: 'translate(-50%, -50%)', textAlign: 'center', cursor: 'pointer', zIndex: selected ? 3 : 1 }}>
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
}, (before, after) => before.selected === after.selected && before.jacked === after.jacked
  && before.focused === after.focused && before.color === after.color && before.onSelect === after.onSelect
  && before.originX === after.originX && before.originY === after.originY
  && ['address', 'name', 'type', 'online', 'access', 'entities', 'px', 'py'].every((key) => before.node[key] === after.node[key]));

const WaypointRoute = (props: { wp: Waypoint; onClear: () => void; onNext: (address: string) => void }) => (
  <Box inline ml={1} color={props.wp.lost || !props.wp.reachable ? THEME.bad : THEME.accent} fontSize="10px">
    <Icon name="route" mr={0.5} />{props.wp.name} · {props.wp.lost ? 'цель потеряна' : props.wp.reachable ? `${props.wp.hops} переходов` : 'нет маршрута'}
    {props.wp.next && <Button compact ml={0.5} icon="arrow-right" content="Следующий узел" onClick={() => props.onNext(props.wp.next)} />}
    <Button compact icon="xmark" ml={0.5} onClick={props.onClear} />
  </Box>
);
