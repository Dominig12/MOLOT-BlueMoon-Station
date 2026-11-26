import { Box, Button, Stack } from '../../components';
import {
  alertShort,
  alertStroke,
  DEFAULT_LAYERS,
  HostView,
  layoutHosts,
  LinkView,
  MapLayers,
  mapExtent,
  MapNode,
  NodeShape,
  pointAlong,
  TravelMarker,
  travelMarkers,
  VisualView,
  visibleHosts,
  visibleLinks,
} from './model';

const RADIUS = 14;

const levelFill = (node: MapNode): string => {
  if (!node.available) {
    return 'rgba(120, 120, 120, 0.35)';
  }
  if (node.stale) {
    return 'rgba(160, 130, 60, 0.45)';
  }
  switch (node.level) {
    case 'identified':
      return 'rgba(70, 150, 220, 0.65)';
    case 'observed':
      return 'rgba(70, 150, 220, 0.35)';
    default:
      return 'rgba(150, 150, 150, 0.35)';
  }
};

/** The ring of one node: the alert colour when that layer is on, the neutral outline otherwise. */
const strokeOf = (node: MapNode, layers: MapLayers): string => {
  if (layers.alerts) {
    const colour = alertStroke(node.alert);
    if (colour) {
      return colour;
    }
  }
  return 'rgba(255, 255, 255, 0.75)';
};

const Shape = ({ node, stroke }: { node: MapNode; stroke: string }) => {
  const fill = levelFill(node);
  switch (node.shape as NodeShape) {
    case 'square':
      return (
        <rect
          x={node.x - RADIUS}
          y={node.y - RADIUS}
          width={RADIUS * 2}
          height={RADIUS * 2}
          rx={3}
          fill={fill}
          stroke={stroke}
        />
      );
    case 'diamond':
      return (
        <polygon
          points={`${node.x},${node.y - RADIUS} ${node.x + RADIUS},${node.y} ${node.x},${node.y + RADIUS} ${
            node.x - RADIUS
          },${node.y}`}
          fill={fill}
          stroke={stroke}
        />
      );
    case 'hexagon': {
      const points: string[] = [];
      for (let i = 0; i < 6; i++) {
        const angle = (Math.PI / 3) * i - Math.PI / 6;
        points.push(`${node.x + RADIUS * Math.cos(angle)},${node.y + RADIUS * Math.sin(angle)}`);
      }
      return <polygon points={points.join(' ')} fill={fill} stroke={stroke} />;
    }
    default:
      return <circle cx={node.x} cy={node.y} r={RADIUS} fill={fill} stroke={stroke} />;
  }
};

const LayerSwitch = ({
  layers,
  onLayers,
}: {
  layers: MapLayers;
  onLayers?: (layers: MapLayers) => void;
}) => (
  <Stack mb={1}>
    <Stack.Item>
      <Button
        compact
        icon="route"
        content="Движение"
        selected={layers.movement}
        tooltip="Реальные переходы присутствий, которые вы можете видеть"
        onClick={() => onLayers?.({ ...layers, movement: !layers.movement })}
      />
    </Stack.Item>
    <Stack.Item>
      <Button
        compact
        icon="triangle-exclamation"
        content="Тревога"
        selected={layers.alerts}
        tooltip="Собственная тревога каждого известного хоста"
        onClick={() => onLayers?.({ ...layers, alerts: !layers.alerts })}
      />
    </Stack.Item>
    <Stack.Item>
      <Button
        compact
        icon="hourglass-half"
        content="Только свежие"
        selected={layers.freshOnly}
        tooltip="Скрыть хосты, знание о которых устарело"
        onClick={() => onLayers?.({ ...layers, freshOnly: !layers.freshOnly })}
      />
    </Stack.Item>
  </Stack>
);

/** One marker of the movement layer: a dashed route and a dot that stands where the move actually is. */
const Marker = ({ marker, from, to }: { marker: TravelMarker; from: MapNode; to: MapNode }) => {
  const colour = marker.own ? '#7fd1ff' : '#f2b24c';
  if (!marker.travelling) {
    return <circle cx={from.x} cy={from.y} r={RADIUS + 4} fill="none" stroke={colour} strokeWidth={1.5} />;
  }
  const at = pointAlong(from, to, marker.progress);
  return (
    <g>
      <line x1={from.x} y1={from.y} x2={to.x} y2={to.y} stroke={colour} strokeWidth={1} strokeDasharray="5 5" />
      <circle cx={at.x} cy={at.y} r={5} fill={colour} stroke="#111" strokeWidth={1} />
    </g>
  );
};

/**
 * The network map. It draws only what the projection contained: a host the observer may not see is not in
 * the list, so it cannot be drawn, counted or hinted at. The movement layer shows real transitions the Host
 * reports — no packet is invented for effect (UI-003, §15.2).
 */
export const NetrunMap = ({
  hosts,
  links,
  visuals,
  now,
  layers = DEFAULT_LAYERS,
  onLayers,
  selected,
  onSelect,
}: {
  hosts: HostView[];
  links: LinkView[];
  visuals?: VisualView[];
  now?: number;
  layers?: MapLayers;
  onLayers?: (layers: MapLayers) => void;
  selected: number | null;
  onSelect: (host: number) => void;
}) => {
  const visible = visibleHosts(hosts, layers.freshOnly);
  const nodes = layoutHosts(visible);
  const shownLinks = visibleLinks(links, visible);
  const extent = mapExtent(nodes);
  const byId = new Map(nodes.map(node => [node.host, node]));
  const markers = layers.movement ? travelMarkers({ hosts, visuals, now }, layers) : [];

  if (nodes.length === 0) {
    return (
      <Box>
        <LayerSwitch layers={layers} onLayers={onLayers} />
        <Box color="label" p={2}>
          Наблюдаемых хостов нет. Отсканируйте сеть, чтобы начать карту.
        </Box>
      </Box>
    );
  }

  return (
    <Box className="NetrunMap" style={{ overflow: 'auto', maxWidth: '100%' }}>
      <LayerSwitch layers={layers} onLayers={onLayers} />
      <svg width={extent.width} height={extent.height} role="group" aria-label="Карта сети">
        {shownLinks.map(link => {
          const a = byId.get(link.a);
          const b = byId.get(link.b);
          if (!a || !b) {
            return null;
          }
          return (
            <line
              key={`${link.a}-${link.b}`}
              x1={a.x}
              y1={a.y}
              x2={b.x}
              y2={b.y}
              stroke="rgba(200, 200, 200, 0.35)"
              strokeWidth={2}
            />
          );
        })}
        {nodes.map(node => (
          <g
            key={node.host}
            onClick={() => onSelect(node.host)}
            style={{ cursor: 'pointer' }}
            role="button"
            aria-label={`Хост ${node.label}`}
          >
            {node.host === selected && (
              <circle cx={node.x} cy={node.y} r={RADIUS + 6} fill="none" stroke="#3f9dfd" strokeWidth={2} />
            )}
            <Shape node={node} stroke={strokeOf(node, layers)} />
            {layers.alerts && alertShort(node.alert) && (
              <text
                x={node.x}
                y={node.y - RADIUS - 6}
                textAnchor="middle"
                fill={alertStroke(node.alert) ?? '#ddd'}
                fontSize={10}
              >
                {alertShort(node.alert)}
              </text>
            )}
            <text x={node.x} y={node.y + RADIUS + 14} textAnchor="middle" fill="#ddd" fontSize={11}>
              {node.label}
              {node.stale ? ' (устар.)' : ''}
            </text>
          </g>
        ))}
        {markers.map(marker => {
          const from = byId.get(marker.from);
          const to = byId.get(marker.to);
          if (!from || !to) {
            return null;
          }
          return <Marker key={`${marker.from}-${marker.to}-${marker.own}`} marker={marker} from={from} to={to} />;
        })}
      </svg>
      <Stack vertical mt={1}>
        <Box color="label" fontSize={11}>
          Форма: ◯ устройство · ▢ точка доступа · ◇ ретранслятор · ⬡ сервер. Яркость — уровень знания,
          жёлтый — устаревшие данные, цветное кольцо и подпись — собственная тревога хоста. Точка на линии —
          реальный переход присутствия: голубая своя, оранжевая чужая (только наблюдаемая).
        </Box>
      </Stack>
    </Box>
  );
};

/** The layer switches alone, for a compact map or a legend in another tab. */
export const NetrunMapLayers = LayerSwitch;
