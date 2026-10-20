import { useState } from 'react';

import { useBackend } from '../../backend';
import { Box, Icon, Stack, Tabs } from '../../components';
import { MatrixPanel } from './Matrix';
import { LanMap, TopologyMap } from './NetworkMap';
import { NodePanel } from './NodePanel';
import { ConsoleLog, EntityPanel, StoragePanel } from './Panels';
import { ACCESS_COLORS, ACCESS_NAMES, NetrunData, THEME } from './types';

const ORIGIN_NAMES: Record<string, string> = {
  terminal: 'Проводной терминал',
  deck: 'Кибердека',
  implant: 'Нейролинк',
  ntos: 'NTOS-клиент',
  entity: 'Резидентный процесс',
  circuit: 'Схема',
};

/** Общее содержимое окна - используется и терминалом, и NTOS-программой */
export const NetrunContent = () => {
  const { act, data } = useBackend<NetrunData>();
  const { view, networks, breach } = data;
  const [mode, setMode] = useState<'topology' | 'lan'>(view ? 'lan' : 'topology');
  return (
    <Box
      style={{
        color: THEME.text,
        background: THEME.panel,
        minHeight: '100%',
        padding: '6px',
      }}
    >
      <Header />
      <EntityPanel />
      <Tabs>
        <Tabs.Tab
          icon="diagram-project"
          selected={mode === 'topology'}
          onClick={() => setMode('topology')}
        >
          Топология
        </Tabs.Tab>
        {networks
          .filter((net) => net.reachable)
          .map((net) => (
            <Tabs.Tab
              key={net.id}
              selected={mode === 'lan' && view?.id === net.id}
              color={net.access > 0 ? undefined : 'grey'}
              onClick={() => {
                act('view_network', { id: net.id });
                setMode('lan');
              }}
            >
              <span style={{ color: net.color }}>{net.short}</span>
              {net.home && <Icon name="location-dot" ml={0.5} />}
            </Tabs.Tab>
          ))}
      </Tabs>
      <Stack>
        <Stack.Item grow basis={0}>
          {breach ? (
            <MatrixPanel state={breach} />
          ) : mode === 'topology' ? (
            <TopologyMap />
          ) : (
            <LanMap />
          )}
          {!breach && mode === 'lan' && view && view.log.length > 0 && (
            <Box
              mt={0.5}
              p={0.5}
              style={{
                background: THEME.bg,
                fontFamily: 'monospace',
                fontSize: '10px',
                maxHeight: '70px',
                overflowY: 'auto',
                color: THEME.muted,
              }}
            >
              {view.log.map((line, i) => (
                <div key={i}>{line}</div>
              ))}
            </Box>
          )}
        </Stack.Item>
        <Stack.Item basis="270px" style={{ minHeight: '360px' }}>
          <NodePanel />
        </Stack.Item>
      </Stack>
      <Stack mt={1}>
        <Stack.Item grow basis={0}>
          <ConsoleLog />
        </Stack.Item>
        <Stack.Item basis="270px" style={{ height: '146px' }}>
          <StoragePanel />
        </Stack.Item>
      </Stack>
      <Legend />
    </Box>
  );
};

const Header = () => {
  const { data } = useBackend<NetrunData>();
  const { origin, uplink, trace, locked, wireless, jack } = data;
  const traceColor = trace > 66 ? THEME.bad : trace > 33 ? THEME.warn : THEME.accent;
  return (
    <Stack align="center" mb={1} style={{ fontFamily: 'monospace' }}>
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
      <Stack.Item grow ml={2}>
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
