import './netrun-workspace.scss';

import { memo, ReactNode, useCallback, useEffect, useRef, useState } from 'react';

import { Box, Button, Icon, Tabs } from '../../components';
import { AppearancePanel } from './AppearancePanel';
import { CombatPanel } from './CombatPanel';
import { MatrixPanel } from './Matrix';
import { MapFocusRequest, StationMap } from './NetworkMap';
import { NodeInteractions } from './NodeInteractions';
import { NodePanel } from './NodePanel';
import { OperationsPanel } from './OperationsPanel';
import { ConsoleLog, EntityPanel, NetChat, StoragePanel } from './Panels';
import { SessionStatus } from './SessionStatus';
import { themeId, themeStyle } from './themes';
import { ACCESS_COLORS, ACCESS_NAMES, NetrunData, THEME, WorkspaceView } from './types';
import { NetrunFeedbackProvider, useNetrunBackend as useBackend, useNetrunSelector } from './useNetrunBackend';
import { WebPanel } from './WebPanel';
import { WindowPanel } from './WindowPanel';

const ORIGIN_NAMES: Record<string, string> = {
  terminal: 'Проводной терминал', deck: 'Кибердека', implant: 'Нейролинк',
  ntos: 'NTOS-клиент', entity: 'Резидентный процесс', circuit: 'Схема',
  pai: 'пИИ', ai: 'ИИ', neural: 'Нейроинтерфейс',
};

const PAGE_NAMES: Record<WorkspaceView, string> = {
  terminal: 'Терминал', map: 'Карта', files: 'Файлы', pinned: 'Закреплённые узлы',
  combat: 'Бой', breach: 'Взлом', web: 'WEB',
};

/** Each workspace remains mounted so navigation preserves drafts, filters and map position. */
export const NetrunContent = memo(() => {
  // TGUI clears data when returning a browser window to its pool. Unmount
  // subscribers together before a later session supplies its first snapshot.
  const ready = useNetrunSelector((data) => !!data.storage && Array.isArray(data.windows) && Array.isArray(data.networks));
  const implant = useNetrunSelector((data) => data.origin === 'implant');
  return ready ? <NetrunFeedbackProvider>{implant ? <ImplantWorkspace /> : <NetrunWorkspace />}</NetrunFeedbackProvider> : null;
});

/** The implant prepares a local entrance; network controls belong to the diver. */
const ImplantWorkspace = () => {
  const { act, data } = useBackend<NetrunData>(['host_actions', 'selected', 'log', 'ui_theme']);
  const selected = data.selected;
  return (
    <Box className="netrun-shell" data-net-theme={themeId(data.ui_theme)}
      style={{ ...themeStyle(data.ui_theme), color: THEME.text, background: THEME.panel, height: '100%', overflowY: 'auto', padding: '8px' }}>
      <Box bold fontSize="16px">Нейролинк</Box>
      <Box mt={0.5} mb={1} color={THEME.muted}>
        Выберите узел в своей зоне и погрузитесь, чтобы управлять сетью.
      </Box>
      <div role="group" aria-label="Действия подключения" style={{ display: 'flex', flexWrap: 'wrap', gap: '4px' }}>
        {(data.host_actions || []).map((action) => (
          <Button key={action.id} compact icon={action.icon} content={action.name} onClick={() => act(action.id)} />
        ))}
      </div>
      <Box mt={1} mb={1} p={1} style={{ background: THEME.bg, border: `1px solid ${THEME.line}` }}>
        {selected ? (
          <>
            <Box bold>Узел погружения: {selected.name}</Box>
            <Box color={THEME.muted}>{selected.address}</Box>
            <NodeInteractions actions={selected.interactions} pending={false} />
          </>
        ) : <Box color={THEME.muted}>Узел погружения не выбран.</Box>}
      </Box>
      {!!data.log?.length && <Box mb={1} color={THEME.muted} role="status">{data.log[data.log.length - 1].text}</Box>}
      <StoragePanel />
    </Box>
  );
};

const NetrunWorkspace = () => {
  const { act } = useBackend([]);
  const data = useNetrunSelector((state) => ({
    workspace_view: state.workspace_view, breach: !!state.breach, web: !!state.web,
    hasWindow: !!state.window, windowCount: state.windows?.length ?? 0,
    incomingCount: state.combat?.incoming?.length ?? 0,
    webAvailable: !!state.networks?.some((network) => network.id === 'web') || !!state.web,
  }));
  const { breach, web } = data;
  const storedPage = data.workspace_view === 'breach' && !breach ? 'terminal' : data.workspace_view;
  const [page, setPage] = useState<WorkspaceView>(() => storedPage
    ?? (breach ? 'breach' : data.hasWindow ? 'pinned' : web ? 'web' : 'terminal'));
  const [terminalTab, setTerminalTab] = useState<'console' | 'chat' | 'operations'>('console');
  const [compact, setCompact] = useState(() => window.innerWidth < 860);
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [mapFocusRequest, setMapFocusRequest] = useState<MapFocusRequest | null>(null);
  const [appearanceOpen, setAppearanceOpen] = useState(false);
  const currentTheme = useNetrunSelector((state) => state.ui_theme);
  const openAppearance = useCallback(() => setAppearanceOpen(true), []);
  const previousPage = useRef<WorkspaceView>(page === 'breach' ? 'terminal' : page);
  const hadBreach = useRef(!!breach);
  const { incomingCount, webAvailable } = data;

  const navigate = useCallback((next: WorkspaceView) => {
    if (next !== 'breach') { previousPage.current = next; }
    setPage(next);
    act('workspace_view', { page: next });
  }, [act]);
  const openCombat = useCallback(() => navigate('combat'), [navigate]);
  const openBreach = useCallback(() => navigate('breach'), [navigate]);
  const openOperations = useCallback(() => { setTerminalTab('operations'); navigate('terminal'); }, [navigate]);
  const locateOperationNode = useCallback((address: string) => {
    setMapFocusRequest((previous) => ({ address, sequence: (previous?.sequence ?? 0) + 1 }));
    navigate('map'); setSidebarOpen(true);
  }, [navigate]);

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
    { id: 'pinned', icon: 'thumbtack', count: data.windowCount },
  ];
  // Keep the tab in a fixed place; a new ICE cast must not insert/remove controls.
  tabs.push({ id: 'combat', icon: 'crosshairs' });
  if (breach) { tabs.push({ id: 'breach', icon: 'key' }); }
  if (webAvailable || page === 'web') { tabs.push({ id: 'web', icon: 'globe' }); }

  return (
    <Box className="netrun-shell" data-net-theme={themeId(currentTheme)} style={{ ...themeStyle(currentTheme), color: THEME.text, background: THEME.panel, height: '100%', minHeight: 0, minWidth: 0,
      display: 'flex', flexDirection: 'column', boxSizing: 'border-box', overflow: 'hidden' }}>
      <Header onAppearance={openAppearance} />
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
      <div className="netrun-status"><SessionStatus onCombat={openCombat} onBreach={openBreach} onOperations={openOperations} /></div>
      <div className="netrun-workspace" data-net-layout="workspace" style={{ display: 'flex', flex: '1 1 0', minHeight: 0, minWidth: 0,
        position: 'relative', borderRadius: '10px', overflow: 'hidden' }}>
        <WorkspacePage id="terminal" active={page}>
          <EntityPanel />
          <Tabs>
            <Tabs.Tab icon="terminal" selected={terminalTab === 'console'} onClick={() => setTerminalTab('console')}>Консоль</Tabs.Tab>
            <Tabs.Tab icon="comments" selected={terminalTab === 'chat'} onClick={() => setTerminalTab('chat')}>#noosphere</Tabs.Tab>
            <Tabs.Tab icon="list-check" selected={terminalTab === 'operations'} onClick={() => setTerminalTab('operations')}>Операции</Tabs.Tab>
          </Tabs>
          <div style={{ display: terminalTab === 'console' ? 'flex' : 'none', flex: '1 1 0', minHeight: 0 }}><ConsoleLog active={page === 'terminal' && terminalTab === 'console'} /></div>
          <div style={{ display: terminalTab === 'chat' ? 'flex' : 'none', flex: '1 1 0', minHeight: 0 }}><NetChat active={page === 'terminal' && terminalTab === 'chat'} /></div>
          <div style={{ display: terminalTab === 'operations' ? 'flex' : 'none', flex: '1 1 0', minHeight: 0 }}>
            <OperationsPanel onLocate={locateOperationNode} />
          </div>
        </WorkspacePage>
        <WorkspacePage id="map" active={page}>
          <div style={{ display: 'flex', flex: '1 1 0', minWidth: 0, minHeight: 0, gap: '7px', position: 'relative' }}>
            <div style={{ flex: '1 1 0', minWidth: 0, minHeight: 0, display: 'flex', flexDirection: 'column' }}>
              <div className="netrun-inspector-toggle" style={{ flex: '0 0 auto', textAlign: 'right', minHeight: '22px' }}>
                <Button compact icon={sidebarOpen ? 'angles-right' : 'angles-left'}
                  content={sidebarOpen ? 'Скрыть информацию об узле' : 'Показать информацию об узле'}
                  onClick={() => setSidebarOpen(!sidebarOpen)} />
              </div>
              <div style={{ flex: '1 1 0', minHeight: 0, minWidth: 0 }}><StationMap suspended={page !== 'map'} focusRequest={mapFocusRequest} /></div>
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
          <PinnedWorkspace active={page === 'pinned'} />
        </WorkspacePage>
        <WorkspacePage id="combat" active={page} scrollable><CombatPanel /></WorkspacePage>
        <WorkspacePage id="breach" active={page} scrollable>
          <BreachWorkspace />
        </WorkspacePage>
        <WorkspacePage id="web" active={page} scrollable>
          <WebWorkspace />
        </WorkspacePage>
      </div>
      {appearanceOpen && <AppearancePanel onClose={() => setAppearanceOpen(false)} />}
    </Box>
  );
};

const BreachWorkspace = memo(() => {
  const breach = useNetrunSelector((data) => data.breach);
  return breach ? <MatrixPanel state={breach} /> : <Box color={THEME.muted} p={1}>Активного взлома нет.</Box>;
});
const WebWorkspace = memo(() => {
  const web = useNetrunSelector((data) => data.web);
  return web ? <WebPanel web={web} /> : <Box color={THEME.muted} p={1}>Ожидание каталога WEB.</Box>;
});
const PinnedWorkspace = memo(({ active }: { active: boolean }) => {
  const { act, data } = useBackend(['workspace_view', 'windows', 'window']);
  const { windows, window: machineWindow } = data;
  const confirmed = useRef<NetrunData['window']>(null);
  if (data.workspace_view === 'pinned') { confirmed.current = machineWindow; }
  const shownWindow = machineWindow || (active && data.workspace_view !== 'pinned' ? confirmed.current : null);
  return (<>
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
          </>);
});

const WorkspacePage = (props: { id: WorkspaceView; active: WorkspaceView; scrollable?: boolean; children: ReactNode }) => (
  <div role="tabpanel" aria-label={PAGE_NAMES[props.id]} aria-hidden={props.active !== props.id}
    data-net-page={props.id} style={{ display: props.active === props.id ? 'flex' : 'none', flex: '1 1 0',
      flexDirection: 'column', width: '100%', minWidth: 0, minHeight: 0,
      overflowX: 'hidden', overflowY: props.scrollable ? 'auto' : 'hidden' }}>
    {props.children}
  </div>
);

const NodeSidebar = memo((props: { suspended: boolean }) => {
  const content = useRef<ReactNode>(null);
  if (!props.suspended) { content.current = <NodePanel />; }
  return content.current;
});
const Header = memo(({ onAppearance }: { onAppearance: () => void }) => {
  const { act, data } = useBackend<NetrunData>(['origin', 'uplink', 'trace', 'locked', 'wireless', 'jack', 'entity', 'host_actions']);
  const { origin, uplink, trace, locked, wireless, jack, entity } = data;
  const traceColor = trace > 66 ? THEME.bad : trace > 33 ? THEME.warn : THEME.accent;
  return (
    <>
    <header className="netrun-header">
      <div className="netrun-header__brand" aria-label="NetRun">
        <span className="netrun-header__logo"><Icon name="network-wired" /></span>
        <span className="netrun-header__title">NETRUN <small>NETWORK OPERATIONS</small></span>
      </div>
      <div className="netrun-header__indicators">
        <Button icon="palette" tooltip="Оформление и сетевая личность" aria-label="Оформление и сетевая личность" onClick={onAppearance} />
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
    {!!data.host_actions?.length && (
      <div role="group" aria-label="Действия подключения"
        style={{ flex: '0 0 auto', display: 'flex', flexWrap: 'wrap', gap: '3px', padding: '5px 0' }}>
        {data.host_actions.map((action) => (
          <Button key={action.id} compact icon={action.icon} content={action.name}
            onClick={() => act(action.id)} />
        ))}
      </div>
    )}
    </>
  );
});

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
