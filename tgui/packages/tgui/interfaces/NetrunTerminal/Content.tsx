import { ReactNode, useEffect, useRef, useState } from 'react';

import { useBackend } from '../../backend';
import { Box, Button, Icon, Stack, Tabs } from '../../components';
import { CombatPanel, IncomingAttacks } from './CombatPanel';
import { MatrixPanel } from './Matrix';
import { StationMap } from './NetworkMap';
import { NodePanel } from './NodePanel';
import { ConsoleLog, EntityPanel, NetChat, StoragePanel } from './Panels';
import { ACCESS_COLORS, ACCESS_NAMES, NetrunData, THEME, WorkspaceView } from './types';
import { WebPanel } from './WebPanel';
import { WindowPanel } from './WindowPanel';

const ORIGIN_NAMES: Record<string, string> = {
  terminal: 'Проводной терминал', deck: 'Кибердека', implant: 'Нейролинк',
  ntos: 'NTOS-клиент', entity: 'Резидентный процесс', circuit: 'Схема',
  pai: 'пИИ', neural: 'Нейроинтерфейс',
};

const PAGE_NAMES: Record<WorkspaceView, string> = {
  terminal: 'Терминал', map: 'Карта', files: 'Файлы', pinned: 'Закреплённые узлы',
  combat: 'Бой', breach: 'Взлом', web: 'WEB',
};

/** Each workspace remains mounted so navigation preserves drafts, filters and map position. */
export const NetrunContent = () => {
  const { act, data } = useBackend<NetrunData>();
  const { breach, web, windows, window: machineWindow } = data;
  const storedPage = data.workspace_view === 'breach' && !breach ? 'terminal' : data.workspace_view;
  const [page, setPage] = useState<WorkspaceView>(() => storedPage
    ?? (breach ? 'breach' : machineWindow ? 'pinned' : web ? 'web' : 'terminal'));
  const [terminalTab, setTerminalTab] = useState<'console' | 'chat'>('console');
  const [compact, setCompact] = useState(() => window.innerWidth < 860);
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const previousPage = useRef<WorkspaceView>(page === 'breach' ? 'terminal' : page);
  const hadBreach = useRef(!!breach);
  const incomingCount = data.combat?.incoming?.length ?? 0;
  const threats = (data.combat?.targets ?? []).filter((target) => target.hostile).length;
  const webAvailable = data.networks.some((network) => network.id === 'web') || !!web;

  const navigate = (next: WorkspaceView) => {
    if (next !== 'breach') { previousPage.current = next; }
    setPage(next);
    act('workspace_view', { page: next });
  };

  useEffect(() => {
    const resize = () => setCompact(window.innerWidth < 860);
    window.addEventListener('resize', resize);
    return () => window.removeEventListener('resize', resize);
  }, []);
  useEffect(() => {
    if (!data.workspace_view) { return; }
    // A closed UI may miss breach completion. Correct that stale server mode once;
    // an already mounted puzzle uses its remembered page in the lifecycle effect.
    if (data.workspace_view === 'breach' && !breach) {
      if (!hadBreach.current) { navigate(previousPage.current); }
      return;
    }
    if (data.workspace_view !== 'breach') { previousPage.current = data.workspace_view; }
    setPage(data.workspace_view);
  }, [data.workspace_view]);
  useEffect(() => {
    if (breach && !hadBreach.current) {
      navigate('breach');
    } else if (!breach && hadBreach.current && page === 'breach') {
      navigate(previousPage.current);
    }
    hadBreach.current = !!breach;
  }, [!!breach]);

  const tabs: { id: WorkspaceView; icon: string; count?: number }[] = [
    { id: 'terminal', icon: 'terminal' },
    { id: 'map', icon: 'diagram-project' },
    { id: 'files', icon: 'folder-open' },
    { id: 'pinned', icon: 'thumbtack', count: windows.length },
  ];
  if (data.combat || incomingCount || page === 'combat') {
    tabs.push({ id: 'combat', icon: 'crosshairs', count: threats || incomingCount });
  }
  if (breach) { tabs.push({ id: 'breach', icon: 'key' }); }
  if (webAvailable || page === 'web') { tabs.push({ id: 'web', icon: 'globe' }); }

  return (
    <Box style={{ color: THEME.text, background: THEME.panel, height: '100%', minHeight: 0, minWidth: 0,
      display: 'flex', flexDirection: 'column', boxSizing: 'border-box', overflow: 'hidden', padding: '8px', gap: '5px' }}>
      <Header />
      <div aria-label="Разделы нетрана" style={{ flex: '0 0 auto', minWidth: 0, overflowX: 'auto' }}>
        <Tabs style={{ width: 'max-content', minWidth: '100%', whiteSpace: 'nowrap', overflow: 'visible' }}>
          {tabs.map((tab) => (
            <Tabs.Tab key={tab.id} icon={tab.icon} selected={page === tab.id}
              onClick={() => navigate(tab.id)} style={tab.id === 'combat' && incomingCount ? { color: THEME.bad } : undefined}>
              {PAGE_NAMES[tab.id]}{tab.count ? ` (${tab.count})` : ''}
            </Tabs.Tab>
          ))}
        </Tabs>
      </div>
      <IncomingAttacks compact onCombat={() => navigate('combat')} />
      <div data-net-layout="workspace" style={{ display: 'flex', flex: '1 1 0', minHeight: 0, minWidth: 0,
        position: 'relative', borderRadius: '7px', overflow: 'hidden' }}>
        <WorkspacePage id="terminal" active={page}>
          <EntityPanel />
          <Tabs>
            <Tabs.Tab icon="terminal" selected={terminalTab === 'console'} onClick={() => setTerminalTab('console')}>Консоль</Tabs.Tab>
            <Tabs.Tab icon="comments" selected={terminalTab === 'chat'} onClick={() => setTerminalTab('chat')}>#noosphere</Tabs.Tab>
          </Tabs>
          <div style={{ display: terminalTab === 'console' ? 'flex' : 'none', flex: '1 1 0', minHeight: 0 }}><ConsoleLog /></div>
          <div style={{ display: terminalTab === 'chat' ? 'flex' : 'none', flex: '1 1 0', minHeight: 0 }}><NetChat /></div>
        </WorkspacePage>
        <WorkspacePage id="map" active={page}>
          <div style={{ display: 'flex', flex: '1 1 0', minWidth: 0, minHeight: 0, gap: '7px', position: 'relative' }}>
            <div style={{ flex: '1 1 0', minWidth: 0, minHeight: 0, display: 'flex', flexDirection: 'column' }}>
              <div style={{ flex: '0 0 auto', textAlign: 'right', minHeight: '22px' }}>
                <Button compact icon={sidebarOpen ? 'angles-right' : 'angles-left'}
                  content={sidebarOpen ? 'Скрыть информацию об узле' : 'Показать информацию об узле'}
                  onClick={() => setSidebarOpen(!sidebarOpen)} />
              </div>
              <div style={{ flex: '1 1 0', minHeight: 0, minWidth: 0 }}><StationMap suspended={page !== 'map'} /></div>
            </div>
            <div data-net-layout="sidebar" style={{ display: sidebarOpen ? 'block' : 'none',
              flex: compact ? 'none' : '0 0 282px', width: compact ? 'min(84%, 310px)' : '282px',
              position: compact ? 'absolute' : 'relative', right: compact ? 0 : undefined, top: compact ? 0 : undefined,
              zIndex: compact ? 7 : undefined, minWidth: 0, minHeight: 0, height: '100%', overflowY: 'auto',
              overflowX: 'hidden', background: '#0d222d', border: `1px solid ${THEME.line}`,
              borderRadius: '7px', boxSizing: 'border-box' }}>
              <NodeSidebar suspended={page !== 'map'} />
            </div>
          </div>
          <Legend />
        </WorkspacePage>
        <WorkspacePage id="files" active={page} scrollable><StoragePanel /></WorkspacePage>
        <WorkspacePage id="pinned" active={page}>
          {windows.length > 0 && (
            <div style={{ flex: '0 0 auto', minWidth: 0, overflowX: 'auto' }}>
              <Tabs style={{ width: 'max-content', minWidth: '100%', whiteSpace: 'nowrap', overflow: 'visible' }}>
                {windows.map((tab) => (
                  <Tabs.Tab key={tab.address} icon={tab.online ? undefined : 'triangle-exclamation'}
                    selected={machineWindow?.address === tab.address}
                    onClick={() => act('window_focus', { address: tab.address })}>
                    {tab.title.length > 24 ? `${tab.title.slice(0, 23)}…` : tab.title}
                    <Icon name="xmark" ml={0.5} title={`Закрыть закреплённый узел ${tab.title}`}
                      onClick={(event) => { event.stopPropagation(); act('window_close', { address: tab.address }); }} />
                  </Tabs.Tab>
                ))}
              </Tabs>
            </div>
          )}
          <div style={{ flex: '1 1 0', minHeight: 0, width: '100%', overflowY: 'auto' }}>
            {machineWindow ? <WindowPanel window={machineWindow} />
              : <Box color={THEME.muted} p={1}>Закреплённых узлов нет. Выберите узел на карте и откройте его окно.</Box>}
          </div>
        </WorkspacePage>
        <WorkspacePage id="combat" active={page} scrollable><CombatPanel /></WorkspacePage>
        <WorkspacePage id="breach" active={page} scrollable>
          {breach ? <MatrixPanel state={breach} /> : <Box color={THEME.muted} p={1}>Активного взлома нет.</Box>}
        </WorkspacePage>
        <WorkspacePage id="web" active={page} scrollable>
          {web ? <WebPanel web={web} /> : <Box color={THEME.muted} p={1}>Ожидание каталога WEB.</Box>}
        </WorkspacePage>
      </div>
    </Box>
  );
};

const WorkspacePage = (props: { id: WorkspaceView; active: WorkspaceView; scrollable?: boolean; children: ReactNode }) => (
  <div role="tabpanel" aria-label={PAGE_NAMES[props.id]} aria-hidden={props.active !== props.id}
    data-net-page={props.id} style={{ display: props.active === props.id ? 'flex' : 'none', flex: '1 1 0',
      flexDirection: 'column', width: '100%', minWidth: 0, minHeight: 0,
      overflowX: 'hidden', overflowY: props.scrollable ? 'auto' : 'hidden' }}>
    {props.children}
  </div>
);

const NodeSidebar = (props: { suspended: boolean }) => {
  const content = useRef<ReactNode>(null);
  if (!props.suspended) { content.current = <NodePanel />; }
  return content.current;
};
const Header = () => {
  const { data } = useBackend<NetrunData>();
  const { origin, uplink, trace, locked, wireless, jack, entity } = data;
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
      {entity && (
        <Stack.Item ml={2} color={entity.integrity > entity.max_integrity * 0.25 ? THEME.text : THEME.bad}>
          Целостность {entity.integrity}/{entity.max_integrity}
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
