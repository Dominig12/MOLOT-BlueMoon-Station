import { memo, useMemo } from 'react';

import { GraphOverlay, markerColor, physicalPoint } from './graphRenderer';
import { GraphScene, PlacedNode } from './graphScene';
import { GraphPoint } from './mapLayout';
import { NetEdge } from './types';

const ACTOR_STYLE = `
@keyframes netrun-threat { 0%,100% { opacity:.85; } 50% { opacity:.3; } }
@keyframes netrun-event { from { opacity:.8; } to { opacity:0; } }
@keyframes netrun-flow { to { stroke-dashoffset:-36; } }
.netrun-threat { animation:netrun-threat 1.6s ease-in-out infinite; }
.netrun-event { animation:netrun-event 4s ease-out both; }
.netrun-flow { animation:netrun-flow 1.2s linear infinite; }
@media (prefers-reduced-motion:reduce) {
  .netrun-threat,.netrun-flow { animation:none; }
}
`;

type Camera = { x: number; y: number; zoom: number; width: number; height: number };
type Props = GraphOverlay & {
  scene: GraphScene;
  dynamicEdges: NetEdge[];
  adjacency: Map<string, Set<string>>;
  camera: Camera;
};

const segment = (from: GraphPoint, to: GraphPoint) => `M${from.px},${from.py}L${to.px},${to.py}`;
const edgeSegment = (scene: GraphScene, edge: NetEdge) => {
  const from = scene.byAddress.get(edge.from), to = scene.byAddress.get(edge.to);
  return from && to ? segment(physicalPoint(from), physicalPoint(to)) : '';
};

const NodeBody = ({ node }: { node: PlacedNode }) => node.type === 'apc'
  ? <rect x={-11} y={-11} width={22} height={22} />
  : ['relay', 'gateway'].includes(node.type)
    ? <path d="M14,0L7,12.12L-7,12.12L-14,0L-7,-12.12L7,-12.12Z" />
    : ['server', 'terminal'].includes(node.type)
      ? <path d="M0,-12L12,0L0,12L-12,0Z" />
      : <circle r={8} />;

/** Only changing markers get DOM elements; thousands of quiet devices remain canvas pixels. */
const NodeActor = memo(({ node, selected, hosted, jacked, color, detailed }: {
  node: PlacedNode; selected: boolean; hosted: boolean; jacked: boolean; color: string; detailed: boolean;
}) => {
  const highlighted = selected || hosted || jacked;
  return (
    <g data-net-actor={node.address} data-net-dynamic-node={node.dynamic ? node.address : undefined} transform={`translate(${node.px} ${node.py})`}>
      {highlighted && <circle data-net-selection r={20} fill="none"
        stroke={selected ? '#eafff5' : hosted ? '#f8a3e6' : '#65b4d5'} strokeWidth={2} />}
      {!!node.ice && <circle className={detailed ? 'netrun-threat' : undefined} r={22}
        fill="none" stroke="#ef6b7c" strokeWidth={1.5} />}
      {!node.ice && node.active && <circle className={detailed ? 'netrun-threat' : undefined} r={18}
        fill="none" stroke="#ffc26b" strokeWidth={1.5} />}
      {node.dynamic && (
        <g data-net-dynamic-body fill={markerColor(node)} stroke={color} strokeWidth={1.5}>
          <NodeBody node={node} />
        </g>
      )}
      {!!node.entities && (
        <g data-net-processes={node.entities} fill="#f19bdc">
          <rect x={10} y={-20} width={detailed ? 12 : 6} height={detailed ? 12 : 6} rx={2} />
          {detailed && <text x={16} y={-11} textAnchor="middle" fill="#2a0f24" fontSize={9} fontWeight={700}>{node.entities > 9 ? '+' : node.entities}</text>}
        </g>
      )}
      {!!node.ice && (
        <g data-net-ice={node.ice} fill="#ff6470">
          <circle cx={-15} cy={-15} r={detailed ? 7 : 3.5} />
          {detailed && <text x={-15} y={-12} textAnchor="middle" fill="#2a0f24" fontSize={9} fontWeight={700}>{node.ice > 9 ? '+' : node.ice}</text>}
        </g>
      )}
    </g>
  );
}, (previous, next) => {
  const a = previous.node, b = next.node;
  return previous.selected === next.selected && previous.hosted === next.hosted && previous.jacked === next.jacked
    && previous.color === next.color && previous.detailed === next.detailed
    && a.px === b.px && a.py === b.py && a.type === b.type && a.dynamic === b.dynamic
    && a.online === b.online && a.access === b.access && a.entities === b.entities && a.ice === b.ice && a.active === b.active;
});

/** Reactive SVG holds moving bodies, their links and volatile overlays; it never draws the base. */
export const ActorLayer = memo((props: Props) => {
  const { scene, camera, dynamicEdges, adjacency, selected, entityHost, jacked, gateways } = props;
  const { x, y, zoom, width, height } = camera;
  const visible = useMemo(() => scene.visible((-x - 32) / zoom, (-y - 32) / zoom,
    (width - x + 32) / zoom, (height - y + 32) / zoom), [scene, x, y, zoom, width, height]);
  const onScreen = (point: GraphPoint) => point.px * zoom + x >= -32 && point.px * zoom + x <= width + 32
    && point.py * zoom + y >= -32 && point.py * zoom + y <= height + 32;
  const route = (addresses: string[]) => {
    let path = '';
    for (let i = 1; i < addresses.length; i++) {
      const from = scene.byAddress.get(addresses[i - 1]), to = scene.byAddress.get(addresses[i]);
      if (from && to && adjacency.get(from.address)?.has(to.address)) { path += segment(physicalPoint(from), physicalPoint(to)); }
    }
    return path;
  };
  const selectedNode = scene.byAddress.get(selected);
  const selectedNeighbors = adjacency.get(selected) || new Set<string>();
  const selectedEdges = selectedNode ? [...selectedNeighbors].map((address) => scene.byAddress.get(address))
    .filter((node): node is PlacedNode => !!node).map((node) => segment(physicalPoint(selectedNode), physicalPoint(node))).join('') : '';
  const denseSelection = selectedNeighbors.size > 24;
  return (
    <svg data-net-actors aria-hidden="true" width="100%" height="100%"
      style={{ position: 'absolute', inset: 0, pointerEvents: 'none', overflow: 'hidden' }}>
      <style>{ACTOR_STYLE}</style>
      <g data-net-camera transform={`translate(${x} ${y}) scale(${zoom})`} fontFamily="monospace" strokeLinejoin="round" strokeLinecap="round">
        <g data-net-dynamic-edges fill="none" strokeWidth={1.5}>
          {dynamicEdges.map((edge) => (<path key={edge.id} data-net-dynamic-edge={edge.id} d={edgeSegment(scene, edge)}
            stroke={edge.online === false ? '#52636e' : edge.kind === 'relay' ? '#3fb8ad' : '#4c8fa7'}
            strokeDasharray={edge.online === false ? '4 5' : undefined} />))}
          {visible.filter((node) => node.dynamic).map((node) => (<path key={`anchor:${node.address}`}
            d={segment(physicalPoint(node), node)} stroke="rgba(117,163,180,.45)" strokeDasharray="2 3" />))}
        </g>
        {zoom >= .6 && <path data-net-selected-edges d={selectedEdges}
          fill="none" stroke="#9ad0e0" strokeWidth={denseSelection ? 1 : 2.5} opacity={denseSelection ? .22 : 1} />}
        <g fill="none" strokeWidth={3.5}>
          <path data-net-route="selected" d={route(props.selectedRoute)} stroke="#50e8c0" strokeDasharray="11 7" className={zoom >= .3 ? 'netrun-flow' : undefined} />
          <path data-net-route="waypoint" d={route(props.waypointRoute)} stroke="#e879b8" strokeDasharray="8 5" className={zoom >= .3 ? 'netrun-flow' : undefined} />
          <path data-net-route="ping" d={route(props.pingRoute)} stroke="#ffc56b" strokeDasharray="4 5" className={zoom >= .3 ? 'netrun-flow' : undefined} />
        </g>
        {visible.filter((node) => node.dynamic || node.entities || node.ice || node.active
          || node.address === selected || node.address === entityHost || node.address === jacked).map((node) => (<NodeActor
            key={node.address} node={node} selected={node.address === selected} hosted={node.address === entityHost}
            jacked={node.address === jacked} color={gateways.get(node.network)?.color || '#82a9ba'} detailed={zoom >= .6} />))}
        {props.events.map((event, index) => {
          const point = scene.byAddress.get(event.to) || scene.byAddress.get(event.from);
          if (event.age >= 4 || !point || !onScreen(point)) { return null; }
          return (<circle key={`${event.kind}:${event.from}:${event.to}:${index}`} data-net-event={event.kind}
            className="netrun-event" cx={point.px} cy={point.py} r={23} fill="none" strokeWidth={1.5}
            stroke={event.kind === 'trace' ? '#f56670' : '#ffc26b'} style={{ animationDelay: `${-event.age}s` }} />);
        })}
      </g>
      <text x={12} y={height - 11} fill="#8faebe" fontFamily="monospace" fontSize={11}>
        Север ↑ · {scene.nodes.length} узлов · {Math.round(zoom * 100)}%
      </text>
    </svg>
  );
});
