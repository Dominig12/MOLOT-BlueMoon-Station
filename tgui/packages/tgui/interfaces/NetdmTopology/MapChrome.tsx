import { Button, Icon } from '../../components';
import { classifyDevices, DEVICE_TYPES, DeviceService } from './devices';
import {
  FLAG_ACCESS_POINT, FLAG_APC, FLAG_BROKEN, FLAG_DEVICE, FLAG_RADIO, FLAG_RELAY,
  FLAG_UNPOWERED, View, ViewNode,
} from './model';

/**
 * Visual overlay inspired by the old NetRun viewport, but it contains no game commands.
 * Both operator and admin screens can reuse it without importing a legacy NetRun model.
 */
type MapChromeProps = {
  level: number;
  nodeCount: number;
  linkCount: number;
  selected?: ViewNode;
  view: View;
  showLegend: boolean;
  playerMap?: boolean;
  deviceServices?: readonly DeviceService[];
  onToggleLegend: () => void;
};

const COLORS = {
  background: 'rgba(7, 19, 30, 0.93)',
  border: 'rgba(90, 198, 221, 0.35)',
  text: '#d5edf7',
  muted: '#9ab2c2',
};

const legendEntries = [
  { name: 'APC / проводная точка', color: '#54c7e4', shape: 'square' },
  { name: 'Мобильное устройство', color: '#f5c66f', shape: 'circle' },
  { name: 'Сетевой узел', color: '#80b1c5', shape: 'circle' },
  { name: 'Нет питания / неисправен', color: '#75818c', shape: 'circle' },
] as const;

const symbol = (color: string, shape: string) => (
  <span
    aria-hidden="true"
    style={{
      width: '9px', height: '9px', background: color, display: 'inline-block',
      borderRadius: shape === 'circle' ? '50%' : '2px', flexShrink: 0,
    }}
  />
);

const panelStyle = {
  color: COLORS.text,
  background: COLORS.background,
  border: `1px solid ${COLORS.border}`,
  borderRadius: '7px',
  padding: '8px 11px',
  fontFamily: 'Consolas, monospace',
  fontSize: '11px',
  boxShadow: '0 7px 24px rgba(0,0,0,.25)',
};

const nodeLabel = (flags: number) => {
  if (flags & FLAG_APC) return 'APC';
  if (flags & FLAG_ACCESS_POINT) return 'точка доступа';
  if (flags & FLAG_RELAY) return 'ретранслятор';
  if (flags & FLAG_DEVICE) return flags & FLAG_RADIO ? 'радиоустройство' : 'проводное устройство';
  return 'сетевой узел';
};

export const MapChrome = ({
  level, nodeCount, linkCount, selected, view, showLegend, playerMap, deviceServices, onToggleLegend,
}: MapChromeProps) => {
  const offline = selected && !!(selected.flags & (FLAG_BROKEN | FLAG_UNPOWERED));
  const wired = [...view.links.values()].filter(link => !link.radio && !link.down).length;
  const radio = [...view.links.values()].filter(link => link.radio).length;
  const down = [...view.links.values()].filter(link => link.down).length;
  const shownKinds = playerMap && showLegend
    ? new Set(Array.from(classifyDevices(view.nodes, deviceServices ?? []).values(), entry => entry.kind))
    : null;

  return (
    <>
      <div
        data-netdm-overlay="hud"
        aria-label="Состояние сетевой карты"
        style={{
          position: 'absolute',
          ...(playerMap ? { top: '12px', left: '12px' } : { bottom: '14px', left: '14px' }),
          pointerEvents: 'none',
          ...panelStyle,
        }}>
        {playerMap ? (
          <>
            <strong>Z{level}</strong>
            <span style={{ marginLeft: '10px', color: COLORS.muted }}>{nodeCount} узлов · {linkCount} связей</span>
          </>
        ) : (
          <div style={{ display: 'flex', alignItems: 'center', gap: '12px' }}>
            <div style={{ textAlign: 'center', color: '#8eeafd', lineHeight: 1.2 }}>
              <strong>С</strong>
              <div style={{ fontSize: '19px' }}>↑</div>
              <span style={{ color: COLORS.muted }}>Ю</span>
            </div>
            <div>
              <div>Сеть · Z{level}</div>
              <div style={{ color: COLORS.muted }}>{nodeCount} узлов · {linkCount} связей</div>
              {selected && (
                <div>
                  {nodeLabel(selected.flags)} #{selected.id}
                  <span style={{ color: offline ? '#ff9e9e' : '#91e5ad' }}>
                    {offline ? ' · не отвечает' : ' · активно'}
                  </span>
                  <div style={{ color: COLORS.muted }}>X {selected.x} · Y {selected.y}</div>
                </div>
              )}
            </div>
          </div>
        )}
      </div>
      <div style={{ position: 'absolute', right: '12px', top: '12px' }}>
        {playerMap ? (
          <button type="button" className="NetdmUnifiedGrid__legend"
            aria-label="Легенда" aria-expanded={showLegend} title="Легенда" onClick={onToggleLegend}>
            <Icon name="info-circle" />
          </button>
        ) : (
          <Button icon="info-circle" onClick={onToggleLegend}>
            {showLegend ? 'Закрыть легенду' : 'Легенда'}
          </Button>
        )}
      </div>
      {showLegend && (
        <div
          data-netdm-overlay="legend"
          role="dialog"
          aria-label="Легенда карты"
          style={{
            position: 'absolute', top: '50px', right: '12px', zIndex: 2,
            width: 'min(245px, calc(100% - 24px))', maxHeight: 'calc(100% - 62px)',
            boxSizing: 'border-box', overflowY: 'auto', ...panelStyle,
          }}>
          <div style={{ fontWeight: 'bold', marginBottom: '8px' }}>Устройства</div>
          {shownKinds ? [...shownKinds].map(kind => {
            const { color, icon, label } = DEVICE_TYPES[kind];
            return (
              <div key={kind} style={{ display: 'flex', alignItems: 'center', gap: '9px', marginBottom: '6px' }}>
                <span aria-hidden="true" style={{
                  display: 'inline-grid', placeItems: 'center', width: '18px', height: '18px', flexShrink: 0,
                  color: `#${color.toString(16)}`, borderRadius: '5px', border: '1px solid currentColor',
                  backgroundColor: '#101e2c',
                }}>
                  <Icon name={icon} />
                </span>
                {label}
              </div>
            );
          }) : legendEntries.map(entry => (
            <div key={entry.name} style={{ display: 'flex', alignItems: 'center', gap: '9px', marginBottom: '7px' }}>
              {symbol(entry.color, entry.shape)} {entry.name}
            </div>
          ))}
          {shownKinds && (
            <>
              <div><span style={{ color: '#d19aff' }}>◆</span> Другие присутствия</div>
              <div style={{ color: COLORS.muted }}>Серые значки отмечают недоступные или устаревшие узлы.</div>
            </>
          )}
          <div style={{ borderTop: `1px solid ${COLORS.border}`, paddingTop: '8px', marginTop: '8px' }}>
            <strong>Связи на уровне</strong>
            <div>Проводные: {wired}</div>
            <div>Радио: {radio}</div>
            <div>Нарушенные: {down}</div>
          </div>
          <div style={{ color: COLORS.muted, marginTop: '10px' }}>
            ЛКМ — выбрать узел · перетаскивание — переместить карту · колесо — масштаб.
            {!playerMap && ' Север всегда сверху.'}
          </div>
        </div>
      )}
    </>
  );
};
