import { Box, Stack } from '../../components';
import { HostView, layoutHosts, LinkView, mapExtent, MapNode, NodeShape, visibleHosts, visibleLinks } from './model';

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

const Shape = ({ node }: { node: MapNode }) => {
  const stroke = 'rgba(255, 255, 255, 0.75)';
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

/**
 * The network map. It draws only what the projection contained: a host the observer may not see is not in
 * the list, so it cannot be drawn, counted or hinted at. Movement of packets is a separate layer that
 * belongs to the presence view, not to this static topology drawing.
 */
export const NetrunMap = ({
  hosts,
  links,
  hideStale,
  selected,
  onSelect,
}: {
  hosts: HostView[];
  links: LinkView[];
  hideStale: boolean;
  selected: number | null;
  onSelect: (host: number) => void;
}) => {
  const visible = visibleHosts(hosts, hideStale);
  const nodes = layoutHosts(visible);
  const shownLinks = visibleLinks(links, visible);
  const extent = mapExtent(nodes);
  const byId = new Map(nodes.map(node => [node.host, node]));

  if (nodes.length === 0) {
    return (
      <Box color="label" p={2}>
        Наблюдаемых хостов нет. Отсканируйте сеть, чтобы начать карту.
      </Box>
    );
  }

  return (
    <Box className="NetrunMap" style={{ overflow: 'auto', maxWidth: '100%' }}>
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
            <Shape node={node} />
            <text x={node.x} y={node.y + RADIUS + 14} textAnchor="middle" fill="#ddd" fontSize={11}>
              {node.label}
              {node.stale ? ' (устар.)' : ''}
            </text>
          </g>
        ))}
      </svg>
      <Stack vertical mt={1}>
        <Box color="label" fontSize={11}>
          Форма: ◯ устройство · ▢ точка доступа · ◇ ретранслятор · ⬡ сервер. Яркость — уровень знания,
          жёлтый — устаревшие данные.
        </Box>
      </Stack>
    </Box>
  );
};
