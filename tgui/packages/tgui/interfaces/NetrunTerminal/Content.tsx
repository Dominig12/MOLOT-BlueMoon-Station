import { ReactNode, useRef, useState } from 'react';

import { useBackend } from '../../backend';
import { Box, Icon, Stack, Tabs } from '../../components';
import { CombatPanel } from './CombatPanel';
import { MatrixPanel } from './Matrix';
import { StationMap } from './NetworkMap';
import { NodePanel } from './NodePanel';
import { ConsoleLog, EntityPanel, NetChat, StoragePanel } from './Panels';
import { ACCESS_COLORS, ACCESS_NAMES, NetrunData, THEME } from './types';
import { WebPanel } from './WebPanel';
import { WindowPanel } from './WindowPanel';

const ORIGIN_NAMES: Record<string, string> = {
  terminal: 'Проводной терминал',
  deck: 'Кибердека',
  implant: 'Нейролинк',
  ntos: 'NTOS-клиент',
  entity: 'Резидентный процесс',
  circuit: 'Схема',
  pai: 'пИИ',
  neural: 'Нейроинтерфейс',
};

/** Общее содержимое окна - используется и терминалом, и NTOS-программой */
export const NetrunContent = () => {
  const { act, data } = useBackend<NetrunData>();
  const { breach, web, windows, window: machineWindow } = data;
  const webAvailable = data.networks.some((n) => n.id === 'web');
  const [bottom, setBottom] = useState<'console' | 'chat' | 'combat'>('console');
  const mapHidden = !!(breach || machineWindow || web);
  const threats = (data.combat?.targets ?? []).filter((t) => t.hostile).length;
  return (
    <Box
      style={{
        color: THEME.text,
        background: THEME.panel,
        height: '100%',
        minHeight: 0,
        minWidth: 0,
        display: 'flex',
        flexDirection: 'column',
        boxSizing: 'border-box',
        overflow: 'auto',
        padding: '6px',
      }}
    >
      <Header />
      <EntityPanel />
      <Tabs>
        <Tabs.Tab
          icon="diagram-project"
          selected={!web}
          onClick={() => act('view_network', { id: 'map' })}
        >
          Сеть
        </Tabs.Tab>
        {webAvailable && (
          <Tabs.Tab
            icon="globe"
            selected={!!web}
            onClick={() => act('view_network', { id: 'web' })}
          >
            WEB
          </Tabs.Tab>
        )}
      </Tabs>
      {windows.length > 0 && (
        <Tabs>
          {windows.map((wtab) => (
            <Tabs.Tab
              key={wtab.address}
              icon={wtab.online ? undefined : 'triangle-exclamation'}
              selected={machineWindow?.address === wtab.address}
              onClick={() => act('window_focus', { address: wtab.address })}
            >
              {wtab.title.length > 12 ? wtab.title.slice(0, 11) + '…' : wtab.title}
              <Icon
                name="xmark"
                ml={0.5}
                onClick={(e) => {
                  e.stopPropagation();
                  act('window_close', { address: wtab.address });
                }}
              />
            </Tabs.Tab>
          ))}
        </Tabs>
      )}
      <div data-net-layout="workspace" style={{ display: 'flex', flex: '1 1 65%', minHeight: '220px', minWidth: 0, overflow: 'hidden' }}>
      {breach && <MatrixPanel state={breach} />}
      {!breach && machineWindow && (
        <Box style={{ height: '100%', width: '100%', minHeight: 0, overflow: 'auto' }}>
          <WindowPanel window={machineWindow} />
        </Box>
      )}
      {!breach && !machineWindow && web && (
        <Box style={{ height: '100%', width: '100%', minHeight: 0, overflow: 'auto' }}>
          <WebPanel web={web} />
        </Box>
      )}
      <div style={{ display: mapHidden ? 'none' : 'flex', flex: '1 1 auto', width: '100%', minHeight: 0, overflow: 'auto', flexWrap: 'wrap', alignItems: 'stretch', gap: '6px' }}>
        <div style={{ flex: '2 1 440px', minWidth: 0, minHeight: '220px', height: '100%' }}>
          <StationMap suspended={mapHidden} />
        </div>
          <div
            style={{
              width: '280px',
              minWidth: '240px',
              maxWidth: '520px',
              flex: '1 1 280px',
              height: '100%',
              minHeight: '220px',
              resize: 'horizontal',
              overflow: 'auto',
            }}
          >
            <NodeSidebar suspended={mapHidden} />
          </div>
      </div>
      </div>
      <div data-net-layout="bottom" style={{ display: 'flex', flex: '0 1 35%', minHeight: '160px', overflow: 'auto', flexWrap: 'wrap', gap: '6px', marginTop: '6px' }}>
        <div style={{ flex: '2 1 440px', minWidth: 0, minHeight: '150px', display: 'flex', flexDirection: 'column' }}>
          <Tabs>
            <Tabs.Tab icon="terminal" selected={bottom === 'console'} onClick={() => setBottom('console')}>
              Консоль
            </Tabs.Tab>
            <Tabs.Tab icon="comments" selected={bottom === 'chat'} onClick={() => setBottom('chat')}>
              #noosphere
            </Tabs.Tab>
            {data.combat && (
              <Tabs.Tab
                icon="crosshairs"
                selected={bottom === 'combat'}
                onClick={() => setBottom('combat')}
                style={threats ? { color: THEME.bad } : undefined}
              >
                Бой{threats ? ` (${threats})` : ''}
              </Tabs.Tab>
            )}
          </Tabs>
          <div style={{ display: bottom === 'console' ? 'flex' : 'none', flex: '1 1 auto', minHeight: 0 }}><ConsoleLog /></div>
          <div style={{ display: bottom === 'chat' ? 'flex' : 'none', flex: '1 1 auto', minHeight: 0 }}><NetChat /></div>
          <div style={{ display: bottom === 'combat' ? 'flex' : 'none', flex: '1 1 auto', minHeight: 0 }}><CombatPanel /></div>
        </div>
        <div style={{ flex: '1 1 270px', minWidth: '240px', minHeight: '150px', height: '100%', overflow: 'auto' }}>
          <StoragePanel />
        </div>
      </div>
      <Legend />
    </Box>
  );
};

const NodeSidebar = (props: { suspended: boolean }) => {
  const content = useRef<ReactNode>(null);
  if (!props.suspended) { content.current = <NodePanel />; }
  return content.current;
};

const Header = () => {
  const { data } = useBackend<NetrunData>();
  const { origin, uplink, trace, locked, wireless, jack } = data;
  const traceColor = trace > 66 ? THEME.bad : trace > 33 ? THEME.warn : THEME.accent;
  return (
    <Stack align="center" mb={1} style={{ fontFamily: 'monospace', flexWrap: 'wrap', rowGap: '4px' }}>
      <Stack.Item>
        <Icon name={wireless ? 'wifi' : 'ethernet'} color={uplink ? THEME.accent : THEME.bad} mr={1} />
        {ORIGIN_NAMES[origin] || origin}
      </Stack.Item>
      <Stack.Item color={uplink ? THEME.good : THEME.bad} ml={2}>
        NTnet: {uplink ? 'связь есть' : 'нет связи'}
      </Stack.Item>
      {jack && (
        <Stack.Item ml={2} color={THEME.good}>
          <Icon name="plug" mr={0.5} />
          {jack.name}
        </Stack.Item>
      )}
      <Stack.Item grow ml={2} style={{ minWidth: '180px' }}>
        {locked > 0 ? (
          <Box color={THEME.bad} bold>
            БЛОКИРОВКА {locked}s
          </Box>
        ) : (
          <Box style={{ position: 'relative', height: '14px', background: THEME.bg, border: `1px solid ${THEME.line}` }}>
            <Box
              style={{
                position: 'absolute',
                left: 0,
                top: 0,
                bottom: 0,
                width: `${trace}%`,
                background: traceColor,
                opacity: 0.7,
                transition: 'width 0.5s',
              }}
            />
            <Box style={{ position: 'relative', fontSize: '10px', lineHeight: '14px', paddingLeft: '4px' }}>
              ТРАССИРОВКА {Math.round(trace)}%
            </Box>
          </Box>
        )}
      </Stack.Item>
    </Stack>
  );
};

const Legend = () => (
  <Box mt={0.5} fontSize="10px" color={THEME.muted} style={{ fontFamily: 'monospace' }}>
    {ACCESS_NAMES.map((name, i) => (
      <Box inline key={name} mr={1.5}>
        <span style={{ color: ACCESS_COLORS[i] }}>●</span> {name}
      </Box>
    ))}
    <Box inline mr={1.5}>
      <span style={{ color: THEME.warn }}>◌</span> активность
    </Box>
    <Box inline>
      <span style={{ color: '#d05090' }}>○</span> резидентный процесс
    </Box>
  </Box>
);
