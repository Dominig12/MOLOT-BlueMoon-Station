import { KeyboardEvent, memo, useCallback, useMemo, useRef, useState } from 'react';

import { useBackend } from '../../backend';
import { Box, Button, Icon, Input } from '../../components';
import { GraphCanvas, GraphCanvasHandle } from './GraphCanvas';
import { createGraphLayoutCache, graphAdjacency, graphNeighborhood, GraphPoint, layoutGraph } from './mapLayout';
import {
  ACCESS_NAMES, NetEdge, NetEvent, NetMap, NetNode, NetrunData, NODE_ICONS,
  NODE_NAMES, PingHop, SearchResult, THEME, Waypoint,
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
  search: SearchResult[];
};
const EMPTY_NODES: NetNode[] = [];
const EMPTY_EDGES: NetEdge[] = [];
const EMPTY_EVENTS: NetEvent[] = [];
const EMPTY_HOPS: PingHop[] = [];
const EMPTY_SEARCH: SearchResult[] = [];

// TGUI polling replaces data objects even if their contents have not changed.
// Retain component references so logs/combat ticks do not trigger map layouts.
const useSemanticValue = <T, >(value: T, signature: string): T => {
  const previous = useRef({ value, signature });
  if (previous.current.signature !== signature) { previous.current = { value, signature }; }
  return previous.current.value;
};

export const StationMap = (props: { suspended?: boolean } = {}) => {
  const { act, data } = useBackend<NetrunData>();
  const latest = useRef<MapInput | null>(null);
  if (!props.suspended) {
    latest.current = {
      map: data.map, selectedAddress: data.selected?.address ?? null,
      selectedNetwork: data.selected_network?.id ?? null, jackAddress: data.jack?.address ?? null,
      entityHost: data.entity?.host ?? null, hasEntity: !!data.entity,
      pingRoute: data.ping_route ?? EMPTY_HOPS, events: data.events ?? EMPTY_EVENTS,
      waypoint: data.waypoint ?? null, search: data.search ?? EMPTY_SEARCH,
    };
  }
  return latest.current ? <MapSnapshot input={latest.current} act={act} /> : null;
};

const MapSnapshot = memo(({ input, act }: { input: MapInput; act: Act }) => {
  const rawNodes = input.map?.nodes ?? EMPTY_NODES;
  const rawEdges = input.map?.edges ?? EMPTY_EDGES;
  // Structural hash excludes mutable activity/access/route/trace fields.
  // The server's topology revision alone is not sufficient: a graph slice can
  // change with search/focus/reveal even when its global revision stays fixed.
  const topologyKey = JSON.stringify([
    input.map?.revision, rawNodes.map((node) => [node.address, node.type, node.uplink]),
    rawEdges.map((edge) => [edge.id, edge.from, edge.to, edge.kind]),
  ]);
  const nodes = useSemanticValue(rawNodes, JSON.stringify(rawNodes.map((node) => [
    node.address, node.type, node.uplink, node.name, node.network, node.sector,
    node.online, node.access, node.entities, node.ice, node.active, node.can_hop,
  ])));
  const edges = useSemanticValue(rawEdges, JSON.stringify(rawEdges));
  const gateways = useSemanticValue(input.map?.gateways ?? [], JSON.stringify(input.map?.gateways ?? []));
  const storedRoute = useSemanticValue(input.map?.route ?? null, JSON.stringify(input.map?.route ?? null));
  const map = useMemo(() => input.map ? { ...input.map, nodes, edges, gateways, route: storedRoute } : null,
    [!!input.map, input.map?.focus, input.map?.depth, nodes, edges, gateways, storedRoute]);
  const pingRoute = useSemanticValue(input.pingRoute, JSON.stringify(input.pingRoute));
  const events = useSemanticValue(input.events, JSON.stringify(input.events));
  const waypoint = useSemanticValue(input.waypoint, JSON.stringify(input.waypoint));
  return (<GraphMap {...input} map={map} topologyKey={topologyKey}
    pingRoute={pingRoute} events={events} waypoint={waypoint} act={act} />);
});

const GraphMap = memo((props: MapInput & { topologyKey: string; act: Act }) => {
  const { act, selectedAddress, selectedNetwork, jackAddress, entityHost, hasEntity,
    map, topologyKey, pingRoute, events, waypoint, search } = props;
  const viewport = useRef<GraphCanvasHandle>(null);
  const [layoutCache] = useState(createGraphLayoutCache);
  const [query, setQuery] = useState('');
  const [focusNearby, setFocusNearby] = useState(false);
  const [disabledTypes, setDisabledTypes] = useState<Record<string, boolean>>({});
  const nodes = map?.nodes ?? EMPTY_NODES;
  const edges = map?.edges ?? EMPTY_EDGES;
  const positions = useMemo(() => layoutGraph(nodes, edges, layoutCache), [topologyKey, layoutCache]);
  const adjacency = useMemo(() => graphAdjacency(nodes, edges), [topologyKey]);
  const liveAdjacency = useMemo(() => graphAdjacency(nodes, edges.filter((edge) => edge.online !== false)), [topologyKey, edges]);
  const placed = useMemo<Placed[]>(() => nodes.map((node) => ({ ...node, ...positions.get(node.address) })), [nodes, positions]);
  const byAddress = useMemo(() => new Map(placed.map((node) => [node.address, node])), [placed]);
  const gateways = useMemo(() => new Map((map?.gateways ?? []).map((gateway) => [gateway.id, gateway])), [map?.gateways]);
  const types = useMemo(() => [...new Set(nodes.map((node) => node.type))].sort(), [nodes]);
  const nearby = useMemo(() => focusNearby && selectedAddress ? graphNeighborhood(adjacency, selectedAddress, 2) : null,
    [focusNearby, selectedAddress, adjacency]);
  const q = query.trim().toLowerCase();
  const visibleNodes = useMemo(() => placed.filter((node) => !disabledTypes[node.type]
    && (!nearby || nearby.has(node.address))
    && (!q || [node.name, node.address, NODE_NAMES[node.type] || node.type, node.sector || '']
      .some((text) => text.toLowerCase().includes(q)))), [placed, disabledTypes, nearby, q]);
  const visibleIds = useMemo(() => new Set(visibleNodes.map((n) => n.address)), [visibleNodes]);
  const visibleEdges = useMemo(() => edges.filter((edge) => visibleIds.has(edge.from) && visibleIds.has(edge.to)), [edges, visibleIds]);
  const visiblePoints = useMemo(() => new Map(visibleNodes.map((n) => [n.address, positions.get(n.address)])), [visibleNodes, positions]);
  // End-to-end routes are never geometrically shortened through omitted nodes:
  // the canvas additionally verifies every adjacent pair against real edges.
  const selectedRoute = map?.route?.reachable ? map.route.route : [];
  const pingAddresses = pingRoute.filter((hop) => hop.kind === 'node').map((hop) => hop.ref);
  const onSelect = useCallback((address: string) => act('select', { address }), [act]);

  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (event.target instanceof HTMLInputElement || event.target instanceof HTMLButtonElement) { return; }
    const key = event.code?.startsWith('Key') ? event.code.slice(3).toLowerCase() : event.key.toLowerCase();
    const directions: Record<string, [number, number]> = { w: [0, -1], s: [0, 1], a: [-1, 0], d: [1, 0] };
    if (!directions[key]) { return; }
    event.preventDefault(); event.stopPropagation();
    const hopping = event.shiftKey && hasEntity;
    const current = byAddress.get(hopping ? entityHost : selectedAddress ?? map?.focus ?? nodes[0]?.address);
    if (!current) { return; }
    const [dx, dy] = directions[key];
    const neighbors = liveAdjacency.get(current.address);
    let best: Placed | null = null;
    let bestScore = Infinity;
    for (const node of visibleNodes) {
      if (node.address === current.address) { continue; }
      const allowed = node.can_hop ?? (node.online && node.access >= 2);
      if (hopping && (!neighbors?.has(node.address) || !allowed)) { continue; }
      const vx = node.px - current.px, vy = node.py - current.py;
      const projection = vx * dx + vy * dy;
      if (projection <= 0 && !hopping) { continue; }
      // A player should still be able to take their only legal link even if
      // the layout put it in another quadrant after a topology change.
      const score = Math.abs(vx * dy - vy * dx) * 2 + Math.hypot(vx, vy)
        + (projection <= 0 ? 100000 : 0);
      if (score < bestScore) { best = node; bestScore = score; }
    }
    if (best) { act(hopping ? 'hop' : 'select', { address: best.address }); }
  };

  if (!map) { return null; }
  if (!nodes.length) { return <Box p={2} color={THEME.muted}>Нет доступных узлов для подключения.</Box>; }
  return (
    <Box data-net-layout="map" onKeyDown={onKeyDown} style={{
      background: '#08131c', border: `1px solid ${THEME.line}`, borderRadius: '7px',
      display: 'flex', flexDirection: 'column', flex: '1 1 auto', height: '100%',
      minHeight: 0, minWidth: 0, boxSizing: 'border-box', overflow: 'hidden',
    }}>
      <Box p={1} style={{ display: 'flex', alignItems: 'center', gap: '5px', flexWrap: 'wrap', borderBottom: `1px solid ${THEME.line}`, background: '#0d222d' }}>
        <Input width="156px" placeholder="поиск узла…" value={query}
          onInput={(_event, value) => setQuery(value)}
          onEnter={(_event, value) => act('search', { text: value })} />
        <Button compact icon="magnifying-glass" tooltip="Поиск узлов по всей сети" onClick={() => act('search', { text: query })} />
        {hasEntity && entityHost && <Button compact icon="location-crosshairs" content="Мой узел"
          onClick={() => { act('focus_host'); viewport.current?.center(entityHost); }} />}
        <Button compact icon="bullseye" content="Рядом" selected={focusNearby} disabled={!selectedAddress}
          tooltip="Показать окружение выбранного узла в 2 переходах" onClick={() => setFocusNearby(!focusNearby)} />
        <Button compact icon="crosshairs" tooltip="К выбранному узлу" disabled={!selectedAddress}
          onClick={() => selectedAddress && viewport.current?.center(selectedAddress)} />
        <Button compact icon="expand" tooltip="Вместить все отфильтрованные узлы" onClick={() => viewport.current?.fit()} />
        <Box style={{ flex: '1 1 auto', minWidth: 0 }} />
        <Box color={THEME.muted} fontSize="10px" style={{ whiteSpace: 'nowrap' }}>
          {visibleNodes.length}/{nodes.length} · глубина {map.depth}
        </Box>
        {map.route && <StoredRouteStatus route={map.route} />}
      </Box>
      <Box p={0.5} style={{ display: 'flex', gap: '4px', flex: '0 0 auto', overflowX: 'auto', overflowY: 'hidden', alignItems: 'center', borderBottom: `1px solid ${THEME.line}` }}>
        {types.map((type) => (<Button key={type} compact icon={NODE_ICONS[type] || 'circle'}
          selected={!disabledTypes[type]} aria-label={`Фильтр: ${NODE_NAMES[type] || type}`}
          tooltip={NODE_NAMES[type] || type}
          onClick={() => setDisabledTypes((old) => ({ ...old, [type]: !old[type] }))} />))}
        <Box ml={1} style={{ width: '1px', alignSelf: 'stretch', background: THEME.line, flexShrink: 0 }} />
        {(map.gateways ?? []).map((gateway) => (<Button key={gateway.id} compact content={gateway.code}
          icon={gateway.has_key ? 'key' : gateway.access ? 'network-wired' : 'lock'}
          selected={selectedNetwork === gateway.id}
          tooltip={`${gateway.name} · ${ACCESS_NAMES[gateway.access]} · защита ${gateway.security}`}
          style={{ color: gateway.color, flexShrink: 0 }} onClick={() => act('select_network', { id: gateway.id })} />))}
      </Box>
      {waypoint && <Box p={0.5} style={{ background: '#12202a', borderBottom: `1px solid ${THEME.line}` }}>
        <WaypointRoute wp={waypoint} onClear={() => act('clear_waypoint')} onNext={(address) => act('select', { address })} />
                   </Box>}
      {search?.length > 0 && <Box p={0.75} style={{ flex: '0 0 auto', maxHeight: '104px', overflowY: 'auto', borderBottom: `1px solid ${THEME.line}`, fontFamily: 'monospace' }}>
        <Box color={THEME.muted} fontSize="10px" mb={0.5}>Найдено в сети: {search.length}
          <Button compact icon="xmark" ml={1} tooltip="Очистить поиск" onClick={() => act('search', { text: '' })} />
        </Box>
        {search.map((result) => (<Box key={result.address} mb={0.5} style={{ display: 'flex', alignItems: 'center', gap: '6px' }}>
          <Icon name={NODE_ICONS[result.type] || 'circle'} color={result.online ? THEME.accent : THEME.bad} />
          <Box style={{ flex: '1 1 auto', minWidth: 0, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
            {result.name} <Box inline color={THEME.muted} fontSize="9px">{result.address}</Box>
          </Box>
          <Button compact icon="location-arrow" selected={waypoint?.address === result.address}
            tooltip="Проложить маршрут" onClick={() => act('set_waypoint', { address: result.address })} />
          {result.visible && <Button compact icon="diagram-project" tooltip="Выбрать на карте" onClick={() => onSelect(result.address)} />}
                                 </Box>))}
                             </Box>}
      <GraphCanvas ref={viewport} adjacency={adjacency} nodes={visibleNodes} edges={visibleEdges} positions={visiblePoints}
        gateways={gateways} selected={selectedAddress} jacked={jackAddress} focus={map.focus}
        entityHost={entityHost} selectedRoute={selectedRoute} waypointRoute={waypoint?.route || []}
        pingRoute={pingAddresses} events={events} onSelect={onSelect} />
      <Box p={0.5} color={THEME.muted} fontSize="10px" style={{ flexShrink: 0, borderTop: `1px solid ${THEME.line}`, background: '#0d222d' }}>
        ЛКМ — выбрать · потянуть — переместить · колесо — масштаб · WASD — выбор{hasEntity ? ' · Shift+WASD — переход' : ''}
      </Box>
    </Box>
  );
});

const StoredRouteStatus = memo(({ route }: { route: NonNullable<NetMap['route']> }) => (<Box
  color={route.reachable ? THEME.accent : THEME.bad} fontSize="10px" title={`Сохранённый маршрут #${route.revision}`}>
  {route.reachable ? `Путь: ${route.hops} пер. · ${Math.round(route.latency)} мс` : 'Путь: нет связи'}
                                                                                        </Box>));
const WaypointRoute = ({ wp, onClear, onNext }: { wp: Waypoint; onClear: () => void; onNext: (address: string) => void }) => (<Box inline
  color={wp.lost || !wp.reachable ? THEME.bad : THEME.accent} fontSize="10px">
  <Icon name="route" mr={1} />{wp.name} · {wp.lost ? 'цель потеряна' : wp.reachable ? `${wp.hops} переходов` : 'нет маршрута'}
  {wp.next && <Button compact ml={1} icon="arrow-right" content="Следующий узел" onClick={() => onNext(wp.next)} />}
  <Button compact icon="xmark" ml={1} onClick={onClear} />
                                                                                                                              </Box>);
