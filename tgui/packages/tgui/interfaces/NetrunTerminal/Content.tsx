import './netrun-workspace.scss';

import { ReactNode, useEffect, useRef, useState } from 'react';

import { Box, Button, Icon, Tabs } from '../../components';
import { CombatPanel } from './CombatPanel';
import { MatrixPanel } from './Matrix';
import { StationMap } from './NetworkMap';
import { NodePanel } from './NodePanel';
import { ConsoleLog, EntityPanel, NetChat, StoragePanel } from './Panels';
import { SessionStatus } from './SessionStatus';
import { ACCESS_COLORS, ACCESS_NAMES, NetrunData, THEME, WorkspaceView } from './types';
import { NetrunFeedbackProvider, useNetrunBackend as useBackend } from './useNetrunBackend';
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
export const NetrunContent = () => <NetrunFeedbackProvider><NetrunWorkspace /></NetrunFeedbackProvider>;

const NetrunWorkspace = () => {
  const { act, data } = useBackend<NetrunData>();
  const { breach, web, windows, window: machineWindow } = data;
  const storedPage = data.workspace_view === 'breach' && !breach ? 'terminal' : data.workspace_view;
  const [page, setPage] = useState<WorkspaceView>(() => storedPage
    ?? (breach ? 'breach' : machineWindow ? 'pinned' : web ? 'web' : 'terminal'));
  const [terminalTab, setTerminalTab] = useState<'console' | 'chat'>('console');
  const [compact, setCompact] = useState(() => window.innerWidth < 860);
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const previousPage = useRef<WorkspaceView>(page === 'breach' ? 'terminal' : page);
  const pinnedWindowCache = useRef<NetrunData['window']>(null);
  if (data.workspace_view === 'pinned') {
    pinnedWindowCache.current = machineWindow;
  }
  const shownWindow = machineWindow || (page === 'pinned' && data.workspace_view !== 'pinned'
    ? pinnedWindowCache.current : null);
  const hadBreach = useRef(!!breach);
  const incomingCount = data.combat?.incoming?.length ?? 0;
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
  // Keep the tab in a fixed place; a new ICE cast must not insert/remove controls.
  tabs.push({ id: 'combat', icon: 'crosshairs' });
  if (breach) { tabs.push({ id: 'breach', icon: 'key' }); }
  if (webAvailable || page === 'web') { tabs.push({ id: 'web', icon: 'globe' }); }

  return (
    <Box className="netrun-shell" style={{ color: THEME.text, background: THEME.panel, height: '100%', minHeight: 0, minWidth: 0,
      display: 'flex', flexDirection: 'column', boxSizing: 'border-box', overflow: 'hidden' }}>
      <Header />
      <div className="netrun-navigation" aria-label="Разделы нетрана">
        <Tabs role="tablist" aria-label="Рабочие страницы" className="netrun-navigation__tabs">
          {tabs.map((tab) => (
            <Tabs.Tab key={tab.id} icon={tab.icon} selected={page === tab.id} role="tab"
              aria-selected={page === tab.id} tabIndex={0}
              aria-label={PAGE_NAMES[tab.id]}
              rightSlot={tab.id === 'combat' && incomingCount ? <span aria-label={`Входящих атак: ${incomingCount}`}>! {incomingCount}</span> : undefined}
              onKeyDown={(event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); navigate(tab.id); } }}
              onClick={() => navigate(tab.id)} style={tab.id === 'combat' && incomingCount ? { color: THEME.bad } : undefined}>
              <span className="netrun-navigation__label">{PAGE_NAMES[tab.id]}{tab.count ? ` (${tab.count})` : ''}</span>
            </Tabs.Tab>
          ))}
        </Tabs>
      </div>
      <div className="netrun-status"><SessionStatus onCombat={() => navigate('combat')} onBreach={() => navigate('breach')} /></div>
      <div className="netrun-workspace" data-net-layout="workspace" style={{ display: 'flex', flex: '1 1 0', minHeight: 0, minWidth: 0,
        position: 'relative', borderRadius: '10px', overflow: 'hidden' }}>
        <WorkspacePage id="terminal" active={page}>
          <EntityPanel />
          <Tabs>
            <Tabs.Tab icon="terminal" selected={terminalTab === 'console'} onClick={() => setTerminalTab('console')}>Консоль</Tabs.Tab>
            <Tabs.Tab icon="comments" selected={terminalTab === 'chat'} onClick={() => setTerminalTab('chat')}>#noosphere</Tabs.Tab>
          </Tabs>
          <div style={{ display: terminalTab === 'console' ? 'flex' : 'none', flex: '1 1 0', minHeight: 0 }}><ConsoleLog active={page === 'terminal' && terminalTab === 'console'} /></div>
          <div style={{ display: terminalTab === 'chat' ? 'flex' : 'none', flex: '1 1 0', minHeight: 0 }}><NetChat active={page === 'terminal' && terminalTab === 'chat'} /></div>
        </WorkspacePage>
        <WorkspacePage id="map" active={page}>
          <div style={{ display: 'flex', flex: '1 1 0', minWidth: 0, minHeight: 0, gap: '7px', position: 'relative' }}>
            <div style={{ flex: '1 1 0', minWidth: 0, minHeight: 0, display: 'flex', flexDirection: 'column' }}>
              <div className="netrun-inspector-toggle" style={{ flex: '0 0 auto', textAlign: 'right', minHeight: '22px' }}>
                <Button compact icon={sidebarOpen ? 'angles-right' : 'angles-left'}
                  content={sidebarOpen ? 'Скрыть информацию об узле' : 'Показать информацию об узле'}
                  onClick={() => setSidebarOpen(!sidebarOpen)} />
              </div>
              <div style={{ flex: '1 1 0', minHeight: 0, minWidth: 0 }}><StationMap suspended={page !== 'map'} /></div>
            </div>
            <div className="netrun-inspector" data-net-layout="sidebar" style={{ display: sidebarOpen ? 'block' : 'none',
              flex: compact ? 'none' : '0 0 320px', width: compact ? 'min(88%, 350px)' : '320px',
              position: compact ? 'absolute' : 'relative', right: compact ? 0 : undefined, top: compact ? 0 : undefined,
              zIndex: compact ? 7 : undefined, minWidth: 0, minHeight: 0, height: '100%', overflowY: 'auto',
              overflowX: 'hidden', background: THEME.panel, border: `1px solid ${THEME.line}`,
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
            {shownWindow ? <WindowPanel window={shownWindow} />
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
    <header className="netrun-header">
      <div className="netrun-header__brand" aria-label="NetRun">
        <span className="netrun-header__logo"><Icon name="network-wired" /></span>
        <span className="netrun-header__title">NETRUN <small>NETWORK OPERATIONS</small></span>
      </div>
      <div className="netrun-header__indicators">
        <span className="netrun-indicator" title={ORIGIN_NAMES[origin] || origin}>
          <Icon name={wireless ? 'wifi' : 'ethernet'} color={uplink ? THEME.accent : THEME.bad} />
          <span>{ORIGIN_NAMES[origin] || origin}</span>
        </span>
        <span className="netrun-indicator" data-state={uplink ? 'online' : 'offline'}>
          <Icon name="circle" /> Реле NTnet: {uplink ? 'доступно' : 'недоступно'}
        </span>
        {!!jack && <span className="netrun-indicator"><Icon name="plug" /> {jack.name}</span>}
        {!!entity && <span className="netrun-indicator" data-state={entity.integrity > entity.max_integrity * 0.25 ? 'online' : 'offline'}>
          Целостность {entity.integrity}/{entity.max_integrity}
                     </span>}
        <div className="netrun-trace" aria-label={locked > 0 ? `Блокировка: ${locked} с` : `Трассировка: ${Math.round(trace)}%`}>
          {locked > 0 ? <strong style={{ color: THEME.bad }}>БЛОКИРОВКА {locked}s</strong> : (
            <>
              <div className="netrun-trace__label">ТРАССИРОВКА <strong>{Math.round(trace)}%</strong></div>
              <div className="netrun-trace__track">
                <div className="netrun-trace__fill" style={{ width: `${Math.max(0, Math.min(100, trace))}%`, background: traceColor }} />
              </div>
            </>
          )}
        </div>
      </div>
    </header>
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
