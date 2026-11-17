import { BooleanLike } from 'common/react';
import { useEffect, useMemo, useRef, useState } from 'react';

import { useBackend } from '../../backend';
import { Box, Button, Dropdown, LabeledList, NoticeBox, Section, Stack, Table } from '../../components';
import { Window } from '../../layouts';
import { MapChrome } from './MapChrome';
import {
  FLAG_ACCESS_POINT,
  FLAG_APC,
  FLAG_BROKEN,
  FLAG_DEVICE,
  FLAG_RADIO,
  FLAG_RELAY,
  FLAG_UNPOWERED,
  parseView,
  View,
  ViewNode,
} from './model';
import { createScene, NodeActivityCounts, NodePresenceCounts, SceneAgent, SceneCancelled, SceneFilters, SceneOperator, SceneRoute, TopologyScene } from './scene';


// The scene resizes its canvas from a ResizeObserver; the browser's loop warning must not reach TGUI's crash handler.
if (typeof window !== 'undefined') {
  window.addEventListener('error', event => {
    if (String(event.message || '').includes('ResizeObserver loop')) {
      event.stopImmediatePropagation();
      event.preventDefault();
    }
  }, true);
}
type Level = { z: number; name: string };

/** DM sends its booleans as 0/1: render them only through `!!`, a bare 0 shows up as text. */
type Data = {
  z: number;
  levels: Level[];
  observing: BooleanLike;
  published: BooleanLike;
  state: string;
  version: string | null;
  age: number | null;
  error: string | null;
  truncated: BooleanLike;
  nodes: unknown[];
  edges: unknown[];
  radio: unknown[];
  down: unknown[];
};

/** Rows the DOM fallback lists at most; the renderer handles the whole bounded view. */
const FALLBACK_ROWS = 300;

const describe = (flags: number) => {
  const parts: string[] = [];
  if (flags & FLAG_APC) {
    parts.push('APC');
  }
  if (flags & FLAG_DEVICE) {
    parts.push(flags & FLAG_RADIO ? 'устройство, радио' : 'устройство, провод');
  }
  if (flags & FLAG_ACCESS_POINT) {
    parts.push('точка доступа');
  }
  if (flags & FLAG_RELAY) {
    parts.push('транзит');
  }
  if (flags & FLAG_UNPOWERED) {
    parts.push('без питания');
  }
  if (flags & FLAG_BROKEN) {
    parts.push('неисправен');
  }
  return parts.join(', ') || 'узел';
};

type CanvasProps = {
  view: View;
  levelKey: string;
  selected: string | null;
  presenceNode?: string | null;
  otherPresences?: NodePresenceCounts;
  activity?: NodeActivityCounts;
  agents?: readonly SceneAgent[];
  operators?: readonly SceneOperator[];
  route?: SceneRoute | null;
  filters: SceneFilters;
  fitRequest: number;
  onSelect: (id: string | null) => void;
  onFailure: (reason: string) => void;
  onReport: (report: RendererReport) => void;
};

/** What the client renderer actually did, for the server log: verifies the real BYOND browser. */
export type RendererReport = {
  /** 'init' after the renderer starts or fails; 'drawn' once the scene first holds a non-empty level. */
  event: 'init' | 'drawn';
  backend?: string;
  failure?: string;
  initMs: number;
  nodes: number;
  links?: number;
  level?: string;
  updateMs?: number;
  dpr: number;
  agent: string;
};

const report = (started: number, nodes: number, result: { backend?: string; failure?: string }): RendererReport => ({
  event: 'init',
  ...result,
  initMs: Math.round(performance.now() - started),
  nodes,
  dpr: window.devicePixelRatio || 1,
  agent: navigator.userAgent.slice(0, 200),
});

/**
 * Hosts one TopologyScene for the lifetime of the component. Data, selection and filters reach
 * the existing scene as updates; the renderer is never recreated by a data change.
 */
export const TopologyCanvas = (props: CanvasProps) => {
  const { onSelect, onFailure, onReport } = props;
  const host = useRef<HTMLDivElement>(null);
  const scene = useRef<TopologyScene | null>(null);
  const latest = useRef(props);
  latest.current = props;
  // The scene keeps these callbacks for its whole life; they always call the latest handlers.
  const handlers = useRef({ onSelect, onFailure, onReport });
  handlers.current = { onSelect, onFailure, onReport };
  const drawn = useRef(false);
  const mounted = useRef(performance.now());

  /**
   * Applies data to the scene. The first non-empty level is reported once per renderer:
   * initMs then counts from mount to the first drawn graph, updateMs is that update alone.
   */
  const apply = (target: TopologyScene, view: View, levelKey: string) => {
    const started = performance.now();
    target.update(view, levelKey);
    if (drawn.current || !view.nodes.size) {
      return;
    }
    drawn.current = true;
    handlers.current.onReport({
      ...report(mounted.current, view.nodes.size, { backend: target.backend }),
      event: 'drawn',
      links: view.links.size,
      level: levelKey,
      updateMs: Math.round(performance.now() - started),
    });
  };

  useEffect(() => {
    let cancelled = false;
    const started = performance.now();
    createScene(host.current!, {
      onSelect: id => handlers.current.onSelect(id),
      onFailure: reason => {
        handlers.current.onReport(report(started, latest.current.view.nodes.size, { failure: reason }));
        handlers.current.onFailure(reason);
      },
    }, () => cancelled)
      .then(created => {
        if (cancelled) {
          created.destroy();
          return;
        }
        scene.current = created;
        const current = latest.current;
        created.setFilters(current.filters);
      created.setActivity(current.activity ?? null);
      created.setAgents(current.agents ?? null);
      created.setOperators(current.operators ?? null);
        handlers.current.onReport(report(started, current.view.nodes.size, { backend: created.backend }));
        apply(created, current.view, current.levelKey);
        created.setSelection(current.selected);
        created.setPresence(current.presenceNode ?? null);
        created.setOtherPresences(current.otherPresences ?? null);
        created.setRoute(current.route ?? null);
      })
      .catch(error => {
        if (!cancelled && !(error instanceof SceneCancelled)) {
          const failure = String(error?.message || error);
          handlers.current.onReport(report(started, latest.current.view.nodes.size, { failure }));
          handlers.current.onFailure(failure);
        }
      });
    return () => {
      cancelled = true;
      scene.current?.destroy();
      scene.current = null;
    };
  }, []);

  useEffect(() => {
    if (scene.current) {
      apply(scene.current, props.view, props.levelKey);
    }
  }, [props.view, props.levelKey]);
  useEffect(() => {
    scene.current?.setSelection(props.selected);
  }, [props.selected]);
  useEffect(() => {
    scene.current?.setPresence(props.presenceNode ?? null);
  }, [props.presenceNode]);
  useEffect(() => {
    scene.current?.setOtherPresences(props.otherPresences ?? null);
  }, [props.otherPresences]);
  useEffect(() => {
    scene.current?.setRoute(props.route ?? null);
  }, [props.route]);
  useEffect(() => {
    scene.current?.setFilters(props.filters);
  }, [props.filters]);
  useEffect(() => {
    scene.current?.setActivity(props.activity ?? null);
  }, [props.activity]);
  useEffect(() => {
    scene.current?.setAgents(props.agents ?? null);
  }, [props.agents]);
  useEffect(() => {
    scene.current?.setOperators(props.operators ?? null);
  }, [props.operators]);
  useEffect(() => {
    if (props.fitRequest) {
      scene.current?.fit();
    }
  }, [props.fitRequest]);

  return <div ref={host} style={{ width: '100%', height: '100%', overflow: 'hidden' }} />;
};

const FallbackList = (props: { view: View; reason: string; selected: string | null;
  onSelect: (id: string) => void; onRetry: () => void }) => {
  const rows = [...props.view.nodes.values()].slice(0, FALLBACK_ROWS);
  return (
    <Section
      fill
      scrollable
      title="Список узлов"
      buttons={<Button icon="redo" onClick={props.onRetry}>Повторить отрисовку</Button>}>
      <NoticeBox>Графический режим недоступен ({props.reason}). Данные показаны списком.</NoticeBox>
      <Table>
        <Table.Row header>
          <Table.Cell>ID</Table.Cell>
          <Table.Cell>X</Table.Cell>
          <Table.Cell>Y</Table.Cell>
          <Table.Cell>Тип</Table.Cell>
        </Table.Row>
        {rows.map(node => (
          <Table.Row key={node.id}>
            <Table.Cell>
              <Button.Checkbox checked={props.selected === node.id} onClick={() => props.onSelect(node.id)}>
                {node.id}
              </Button.Checkbox>
            </Table.Cell>
            <Table.Cell>{node.x}</Table.Cell>
            <Table.Cell>{node.y}</Table.Cell>
            <Table.Cell>{describe(node.flags)}</Table.Cell>
          </Table.Row>
        ))}
      </Table>
      {props.view.nodes.size > rows.length && <Box color="label">Показано {rows.length} из {props.view.nodes.size}.</Box>}
    </Section>
  );
};

const Inspector = (props: { view: View; node: ViewNode | undefined }) => {
  const { node, view } = props;
  if (!node) {
    return <Section fill title="Узел">Выберите узел на карте.</Section>;
  }
  const wired: string[] = [];
  const radio: string[] = [];
  const silent: string[] = [];
  for (const link of view.links.values()) {
    if (link.a === node.id || link.b === node.id) {
      (link.radio ? radio : link.down ? silent : wired).push(link.a === node.id ? link.b : link.a);
    }
  }
  return (
    <Section fill scrollable title={`Узел ${node.id}`}>
      <LabeledList>
        <LabeledList.Item label="Тип">{describe(node.flags)}</LabeledList.Item>
        <LabeledList.Item label="Клетка">{node.x}, {node.y}</LabeledList.Item>
        <LabeledList.Item label="Провод">{wired.length ? wired.slice(0, 12).join(', ') : 'нет'}</LabeledList.Item>
        {!!silent.length && (
          <LabeledList.Item label="Провод без связи">{silent.slice(0, 12).join(', ')}</LabeledList.Item>
        )}
        <LabeledList.Item label="Радио">{radio.length ? radio.slice(0, 12).join(', ') : 'нет'}</LabeledList.Item>
      </LabeledList>
    </Section>
  );
};

export const NetdmTopology = () => {
  const { act, data } = useBackend<Data>();
  const view = useMemo(
    () => parseView({ nodes: data.nodes, edges: data.edges, radio: data.radio, down: data.down }),
    [data.nodes, data.edges, data.radio, data.down],
  );
  const [selected, setSelected] = useState<string | null>(null);
  const [filters, setFilters] = useState<SceneFilters>({ radio: true, devices: true });
  const [failure, setFailure] = useState<string | null>(null);
  const [fitRequest, setFitRequest] = useState(0);
  const [showLegend, setShowLegend] = useState(false);
  const levels = data.levels ?? [];
  const levelKey = String(data.z);

  return (
    <Window width={960} height={640} title="netDM: топология сети">
      <Window.Content>
        <Stack fill vertical>
          <Stack.Item>
            <Section>
              <Stack align="center" wrap>
                <Stack.Item>
                  <Dropdown
                    width="220px"
                    selected={data.z}
                    options={levels.map(level => ({ value: level.z, displayText: `${level.name} (Z${level.z})` }))}
                    onSelected={(value: number) => {
                      setSelected(null);
                      act('set_z', { z: value });
                    }} />
                </Stack.Item>
                <Stack.Item>
                  <Button icon="sync" onClick={() => act('refresh')}>Обновить</Button>
                </Stack.Item>
                <Stack.Item>
                  <Button icon="expand" disabled={!!failure} onClick={() => setFitRequest(fitRequest + 1)}>Вписать</Button>
                </Stack.Item>
                <Stack.Item>
                  <Button.Checkbox checked={filters.devices} onClick={() => setFilters({ ...filters, devices: !filters.devices })}>
                    Устройства
                  </Button.Checkbox>
                </Stack.Item>
                <Stack.Item>
                  <Button.Checkbox checked={filters.radio} onClick={() => setFilters({ ...filters, radio: !filters.radio })}>
                    Радиосвязи
                  </Button.Checkbox>
                </Stack.Item>
                <Stack.Item grow>
                  <Box color="label" textAlign="right">
                    {view.nodes.size} узлов, {view.links.size} связей
                    {data.version !== null && data.version !== undefined && ` · версия ${data.version}`}
                    {data.age !== null && data.age !== undefined && ` · ${data.age} с назад`}
                  </Box>
                </Stack.Item>
              </Stack>
              {!data.observing && <NoticeBox danger>netDM Observe выключен.</NoticeBox>}
              {!!data.observing && !data.published && <NoticeBox>Карта ещё не опубликована в Host.</NoticeBox>}
              {!!data.error && <NoticeBox danger>Host: {data.error}</NoticeBox>}
              {!!data.truncated && <NoticeBox warning>Показана ограниченная часть уровня.</NoticeBox>}
            </Section>
          </Stack.Item>
          <Stack.Item grow>
            <Stack fill>
              <Stack.Item grow>
                {failure ? (
                  <FallbackList
                    view={view}
                    reason={failure}
                    selected={selected}
                    onSelect={setSelected}
                    onRetry={() => setFailure(null)} />
                ) : (
                  <div style={{ position: 'relative', height: '100%', width: '100%' }}>
                    <TopologyCanvas
                    view={view}
                    levelKey={levelKey}
                    selected={selected}
                    filters={filters}
                    fitRequest={fitRequest}
                    onSelect={setSelected}
                    onFailure={setFailure}
                      onReport={rendererReport => act('renderer', rendererReport)} />
                    <MapChrome
                      level={data.z}
                      nodeCount={view.nodes.size}
                      linkCount={view.links.size}
                      selected={selected ? view.nodes.get(selected) : undefined}
                      view={view}
                      showLegend={showLegend}
                      onToggleLegend={() => setShowLegend(value => !value)} />
                  </div>
                )}
              </Stack.Item>
              <Stack.Item basis="260px">
                <Inspector view={view} node={selected ? view.nodes.get(selected) : undefined} />
              </Stack.Item>
            </Stack>
          </Stack.Item>
        </Stack>
      </Window.Content>
    </Window>
  );
};
