import {
  type DragEvent as ReactDragEvent,
  useCallback,
  useEffect,
  useRef,
  useState,
} from 'react';

import { resolveAsset } from '../../assets';
import { useBackend } from '../../backend';
import {
  Box,
  Button,
  Icon,
  InfinitePlane,
  Input,
  Section,
  Stack,
} from '../../components';
import { Window } from '../../layouts';
import {
  byondListToArray,
  connectedToRefList,
  normalizeCircuitComponent,
} from './byondPayload';
import { CircuitInfo } from './CircuitInfo';
import { CircuitToolbar } from './CircuitToolbar';
import { Connections } from './Connections';
import { ABSOLUTE_Y_OFFSET, MOUSE_BUTTON_LEFT } from './constants';
import { Minimap } from './Minimap';
import { ObjectComponent } from './ObjectComponent';
import { PinEditor } from './PinEditor';
import type {
  CircuitComponentView,
  CircuitPortPayload,
  CircuitPulse,
  GroupDragState,
  IntegratedCircuitData,
  PortLocation,
  SelectedPortState,
  WireConnection,
} from './types';
import { VariableMenu } from './VariableMenu';

/** Карта REF порта → подпись «Компонент · Порт» для попапа порядка связей. */
function buildPortLabelByRef(
  components: (CircuitComponentView | null)[],
): Map<string, string> {
  const portLabelByRef = new Map<string, string>();
  for (const comp of components) {
    if (!comp) {
      continue;
    }
    const compLabel = comp.name || '';
    for (const p of comp.input_ports) {
      portLabelByRef.set(p.ref, `${compLabel} · ${p.name}`);
    }
    for (const p of comp.output_ports) {
      portLabelByRef.set(p.ref, `${compLabel} · ${p.name}`);
    }
  }
  return portLabelByRef;
}

/** Ключи «живых» импульсов проводов: out\0in. IE отдаёт список, wiremod — один ref. */
function buildPulseKeys(
  circuit_pulses: CircuitPulse[] | null | undefined,
  circuit_pulse_out_ref: string | null | undefined,
  circuit_pulse_in_ref: string | null | undefined,
): Set<string> {
  const pulseKeys = new Set<string>();
  if (Array.isArray(circuit_pulses)) {
    for (const pulse of circuit_pulses) {
      if (pulse && pulse.out && pulse.in) {
        pulseKeys.add(`${pulse.out}\u0000${pulse.in}`);
      }
    }
  }
  else if (circuit_pulse_out_ref && circuit_pulse_in_ref) {
    pulseKeys.add(`${circuit_pulse_out_ref}\u0000${circuit_pulse_in_ref}`);
  }
  return pulseKeys;
}

/**
 * Стабильная ссылка на колбэк, который всегда вызывает свою самую свежую
 * версию. Нужна для window.addEventListener/removeEventListener в функциональном
 * компоненте: добавление и удаление используют один и тот же обёрточный `fn`,
 * а его тело читается из `ref` на момент вызова (свежие state/data).
 */
function useStableCallback<A extends unknown[], R>(
  fn: (...args: A) => R,
): (...args: A) => R {
  const ref = useRef(fn);
  ref.current = fn;
  return useCallback((...args: A) => ref.current(...args), []);
}

type TargetPort = { index: number; component_id: number; is_output: boolean };

export const IntegratedCircuit = () => {
  const { act, data } = useBackend<IntegratedCircuitData>();

  const [locations, setLocations] = useState<Record<string, PortLocation>>({});
  const [selectedPort, setSelectedPort] = useState<SelectedPortState | null>(null);
  const [connectSource, setConnectSource] = useState<SelectedPortState | null>(null);
  const [dragClientX, setDragClientX] = useState<number | null>(null);
  const [dragClientY, setDragClientY] = useState<number | null>(null);
  const [zoom, setZoom] = useState(1);
  const [menuOpen, setMenuOpen] = useState(false);
  const [screenPanOverride, setScreenPanOverride] = useState<{ x: number; y: number } | null>(null);
  const [planeHomeNonce, setPlaneHomeNonce] = useState(0);
  const [componentsPanelOpen, setComponentsPanelOpen] = useState(false);
  const [componentsFilter, setComponentsFilter] = useState('');
  const [selection, setSelection] = useState<number[]>([]);
  const [dragState, setDragState] = useState<GroupDragState | null>(null);
  /** Рамка выделения (marquee) в экранных координатах: x0..x1, y0..y1. */
  const [marquee, setMarquee] = useState<{ x0: number; y0: number; x1: number; y1: number } | null>(null);
  /** Индекс (1-based) строки списка компонентов, над которой висит drag (подсветка). */
  const [componentDragOver, setComponentDragOver] = useState<number | null>(null);

  const connectionsSvgRef = useRef<SVGSVGElement | null>(null);
  /** Смещали ли поле мышью с прошлого сохранённого screen_x/y (не слать move_screen на каждый mouseup). */
  const planePanDirty = useRef(false);
  const backgroundX = useRef(0);
  const backgroundY = useRef(0);
  /** Однократная инициализация якоря панорамы из server screen_x/y для миникарты. */
  const panInitialized = useRef(false);
  /** Позиции портов, ожидающие перемеривания (одно измерение на кадр). */
  const locationPending = useRef<Map<string, { port: CircuitPortPayload; dom: HTMLElement }>>(new Map());
  const locationRaf = useRef<number | null>(null);
  /** Актуальный нормализованный массив компонентов (для группового драга). */
  const latestComponents = useRef<(CircuitComponentView | null)[]>([]);
  const portDragStartX = useRef(0);
  const portDragStartY = useRef(0);
  const portDragMoved = useRef(false);
  /** Свежий zoom и locations для обратных вызовов, которые читают их вне render (RAF/слушатели). */
  const zoomRef = useRef(1);
  const locationsRef = useRef<Record<string, PortLocation>>({});
  zoomRef.current = zoom;
  locationsRef.current = locations;

  /** Состояние marquee-выделения (не в state, т.к. активно только в момент драга). */
  const marqueeStart = useRef<{ x: number; y: number; additive: boolean } | null>(null);
  const marqueeBaseSelection = useRef<number[]>([]);
  const marqueeNodeRects = useRef<{ index: number; left: number; top: number; right: number; bottom: number }[]>([]);
  const marqueeMoved = useRef(false);
  const lastMarqueeSelection = useRef<number[]>([]);
  /** Источник перетаскивания в списке компонентов (1-based индекс). */
  const componentReorderSrc = useRef<number | null>(null);

  /** Кэш данных, зависящих от payload сервера; ключ — сам объект `data`. */
  const memoDataKey = useRef<unknown>(null);
  const memoComponents = useRef<(CircuitComponentView | null)[]>([]);
  const memoPortLabelByRef = useRef<Map<string, string>>(new Map());
  const memoPulseKeys = useRef<Set<string>>(new Set());
  const memoConnInputs = useRef<unknown[] | null>(null);
  const memoConnections = useRef<WireConnection[] | null>(null);

  const getPosition = (el: HTMLElement | null): PortLocation => {
    if (!el) {
      return { x: 0, y: 0 };
    }
    const svg = connectionsSvgRef.current;
    const portRect = el.getBoundingClientRect?.();
    // Мировые координаты получаем через обратную CTM самого SVG (включает
    // translate+scale контейнера), а не делением на «zoom» из state — иначе при
    // рассинхронизации zoom (например, после fit-to-view) провода «уплывают».
    if (portRect && svg && portRect.width >= 0) {
      const ctm = svg.getScreenCTM();
      if (ctm) {
        try {
          const inv = ctm.inverse();
          const pt = svg.createSVGPoint();
          pt.x = portRect.left + portRect.width / 2;
          pt.y = portRect.top + portRect.height / 2;
          const local = pt.matrixTransform(inv);
          if (!Number.isNaN(local.x) && !Number.isNaN(local.y)) {
            return { x: local.x, y: local.y };
          }
        }
        catch {
          // fall through to offset fallback
        }
      }
    }

    let xPos = 0;
    let yPos = 0;
    let node: HTMLElement | null = el;
    while (node) {
      xPos += node.offsetLeft;
      yPos += node.offsetTop;
      node = node.offsetParent as HTMLElement | null;
    }
    const w = el.offsetWidth || 0;
    const h = el.offsetHeight || 0;
    return {
      x: xPos + w / 2,
      y: yPos + h / 2 + ABSOLUTE_Y_OFFSET,
    };
  };

  /** Фактический масштаб поля (из CTM SVG), не зависящий от синхронизации zoom в state. */
  const readPlaneScale = () => {
    const svg = connectionsSvgRef.current;
    if (svg) {
      const cw = svg.clientWidth;
      const rectW = svg.getBoundingClientRect().width;
      if (cw > 0 && rectW > 0) {
        return rectW / cw;
      }
    }
    return zoomRef.current || 1;
  };

  /** Экранные прямоугольники всех узлов (для marquee), измеряются один раз в момент старта. */
  const measureNodeRects = () => {
    const svg = connectionsSvgRef.current;
    if (!svg) {
      return [];
    }
    const host = svg.parentElement;
    if (!host) {
      return [];
    }
    const nodes = host.querySelectorAll<HTMLElement>('[data-ic-component-id]');
    const out: { index: number; left: number; top: number; right: number; bottom: number }[] = [];
    nodes.forEach((node) => {
      const raw = node.getAttribute('data-ic-component-id');
      const index = raw ? Number(raw) : 0;
      const r = node.getBoundingClientRect();
      out.push({ index, left: r.left, top: r.top, right: r.right, bottom: r.bottom });
    });
    return out;
  };

  const flushPortLocations = () => {
    const pending = locationPending.current;
    if (pending.size === 0) {
      return;
    }
    locationPending.current = new Map();
    let next: Record<string, PortLocation> | null = null;
    pending.forEach(({ port, dom }) => {
      if (!dom.isConnected) {
        return;
      }
      const position = getPosition(dom);
      const withColor = { x: position.x, y: position.y, color: port.color };
      if (Number.isNaN(withColor.x) || Number.isNaN(withColor.y)) {
        return;
      }
      const last = locationsRef.current[port.ref];
      if (last && last.x === withColor.x && last.y === withColor.y) {
        return;
      }
      if (!next) {
        next = { ...locationsRef.current };
      }
      next[port.ref] = withColor;
    });
    if (next) {
      setLocations(next);
    }
  };

  const handlePortLocation = (port: CircuitPortPayload, dom: HTMLElement | null) => {
    if (!dom || !dom.isConnected) {
      return;
    }
    locationPending.current.set(port.ref, { port, dom });
    if (locationRaf.current === null) {
      locationRaf.current = requestAnimationFrame(() => {
        locationRaf.current = null;
        flushPortLocations();
      });
    }
  };

  const connectPins = (source: SelectedPortState, target: TargetPort) => {
    let payload;
    if (target.is_output) {
      payload = {
        input_port_id: source.index,
        output_port_id: target.index,
        input_component_id: source.component_id,
        output_component_id: target.component_id,
      };
    }
    else {
      payload = {
        input_port_id: target.index,
        output_port_id: source.index,
        input_component_id: target.component_id,
        output_component_id: source.component_id,
      };
    }
    act('add_connection', payload);
  };

  const handlePortDrag = useStableCallback((event: MouseEvent) => {
    if (!portDragMoved.current) {
      const dx = event.clientX - portDragStartX.current;
      const dy = event.clientY - portDragStartY.current;
      if (dx * dx + dy * dy < 9) {
        return;
      }
      portDragMoved.current = true;
    }
    setDragClientX(event.clientX);
    setDragClientY(event.clientY);
  });

  const handlePortRelease = useStableCallback((_event: MouseEvent) => {
    const sel = selectedPort;
    if (sel && !portDragMoved.current) {
      setConnectSource(sel);
      setSelectedPort(null);
      setDragClientX(null);
      setDragClientY(null);
    }
    else {
      setSelectedPort(null);
      setDragClientX(null);
      setDragClientY(null);
    }
    portDragMoved.current = false;

    window.removeEventListener('mousemove', handlePortDrag);
    window.removeEventListener('mouseup', handlePortRelease);
  });

  const handleNodeDrag = useStableCallback((event: MouseEvent) => {
    if (!dragState) {
      return;
    }
    event.preventDefault();
    const z = readPlaneScale();
    const deltaX = (event.clientX - dragState.startClientX) / z;
    const deltaY = (event.clientY - dragState.startClientY) / z;
    if (deltaX !== dragState.deltaX || deltaY !== dragState.deltaY) {
      setDragState((s) => (s ? { ...s, deltaX, deltaY } : null));
    }
  });

  const handleNodeDragEnd = useStableCallback(() => {
    window.removeEventListener('mousemove', handleNodeDrag);
    window.removeEventListener('mouseup', handleNodeDragEnd);
    if (dragState) {
      const moved = dragState.deltaX !== 0 || dragState.deltaY !== 0;
      if (moved) {
        for (const id of dragState.ids) {
          const start = dragState.startPositions[id];
          if (!start) {
            continue;
          }
          act('set_component_coordinates', {
            component_id: id,
            rel_x: Math.round(start.x + dragState.deltaX),
            rel_y: Math.round(start.y + dragState.deltaY),
          });
        }
      }
    }
    setDragState(null);
  });

  const handleMarqueeMove = useStableCallback((event: MouseEvent) => {
    const start = marqueeStart.current;
    if (!start) {
      return;
    }
    marqueeMoved.current = true;
    const x0 = Math.min(start.x, event.clientX);
    const y0 = Math.min(start.y, event.clientY);
    const x1 = Math.max(start.x, event.clientX);
    const y1 = Math.max(start.y, event.clientY);
    setMarquee({ x0, y0, x1, y1 });

    const inside = marqueeNodeRects.current
      .filter((nr) => nr.right >= x0 && nr.left <= x1 && nr.bottom >= y0 && nr.top <= y1)
      .map((nr) => nr.index);
    const next = start.additive
      ? Array.from(new Set([...marqueeBaseSelection.current, ...inside]))
      : inside;
    if (
      next.length !== lastMarqueeSelection.current.length
      || next.some((v, i) => v !== lastMarqueeSelection.current[i])
    ) {
      lastMarqueeSelection.current = next;
      setSelection(next);
    }
  });

  const handleMarqueeEnd = useStableCallback(() => {
    window.removeEventListener('mousemove', handleMarqueeMove);
    window.removeEventListener('mouseup', handleMarqueeEnd);
    const start = marqueeStart.current;
    if (start && !marqueeMoved.current && !start.additive) {
      // Клик по пустому полю без перетаскивания — снять выделение.
      setSelection([]);
    }
    marqueeStart.current = null;
    marqueeBaseSelection.current = [];
    marqueeNodeRects.current = [];
    marqueeMoved.current = false;
    lastMarqueeSelection.current = [];
    setMarquee(null);
  });

  /** ЛКМ по пустому полю — начало marquee-выделения (вместо панорамы). */
  const handlePlaneMouseDown = (event: MouseEvent) => {
    if (event.button !== MOUSE_BUTTON_LEFT) {
      return;
    }
    event.stopPropagation();
    event.preventDefault();
    marqueeNodeRects.current = measureNodeRects();
    marqueeBaseSelection.current = selection;
    marqueeStart.current = {
      x: event.clientX,
      y: event.clientY,
      additive: event.shiftKey || event.ctrlKey || event.metaKey,
    };
    marqueeMoved.current = false;
    lastMarqueeSelection.current = selection;
    setMarquee({ x0: event.clientX, y0: event.clientY, x1: event.clientX, y1: event.clientY });
    window.addEventListener('mousemove', handleMarqueeMove);
    window.addEventListener('mouseup', handleMarqueeEnd);
  };

  const handleMouseDown = useStableCallback((_event: MouseEvent) => {
    if (data.examined_name) {
      act('remove_examined_component');
    }
    if (selection.length) {
      setSelection([]);
    }
  });

  const handleWindowKeyDown = useStableCallback((event: KeyboardEvent) => {
    if (event.key !== 'Escape') {
      return;
    }
    if (!connectSource && !selectedPort && selection.length === 0) {
      return;
    }
    setConnectSource(null);
    setSelectedPort(null);
    setSelection([]);
  });

  const handleMouseUp = useStableCallback((_event: MouseEvent) => {
    if (!planePanDirty.current) {
      return;
    }
    planePanDirty.current = false;
    act('move_screen', {
      screen_x: backgroundX.current,
      screen_y: backgroundY.current,
    });
  });

  const handlePortClick = (
    portIndex: number,
    componentId: number,
    port: CircuitPortPayload,
    isOutput: boolean,
    event: MouseEvent,
  ) => {
    if (event.button !== MOUSE_BUTTON_LEFT) {
      return;
    }

    event.stopPropagation();

    const src = connectSource;
    if (src) {
      if (src.ref === port.ref) {
        setConnectSource(null);
      }
      else if (src.is_output === isOutput) {
        setConnectSource({
          index: portIndex,
          component_id: componentId,
          is_output: isOutput,
          ref: port.ref,
        });
      }
      else {
        connectPins(src, {
          index: portIndex,
          component_id: componentId,
          is_output: isOutput,
        });
        setConnectSource(null);
      }
      return;
    }

    portDragMoved.current = false;
    portDragStartX.current = event.clientX;
    portDragStartY.current = event.clientY;
    setSelectedPort({
      index: portIndex,
      component_id: componentId,
      is_output: isOutput,
      ref: port.ref,
    });

    handlePortDrag(event);

    window.addEventListener('mousemove', handlePortDrag);
    window.addEventListener('mouseup', handlePortRelease);
  };

  const handlePortUp = (
    portIndex: number,
    componentId: number,
    _port: CircuitPortPayload,
    isOutput: boolean,
    _event: MouseEvent,
  ) => {
    if (!selectedPort) {
      return;
    }
    if (selectedPort.is_output === isOutput) {
      return;
    }
    connectPins(selectedPort, {
      index: portIndex,
      component_id: componentId,
      is_output: isOutput,
    });
  };

  const handlePortRightClick = (
    portIndex: number,
    componentId: number,
    _port: CircuitPortPayload,
    isOutput: boolean,
    event: MouseEvent,
  ) => {
    event.preventDefault();
    act('remove_connection', {
      component_id: componentId,
      is_input: !isOutput,
      port_id: portIndex,
    });
  };

  const handleZoomChange = (newZoom: number) => {
    setZoom(newZoom);
  };

  const handleBackgroundMoved = (newX: number, newY: number) => {
    planePanDirty.current = true;
    backgroundX.current = newX;
    backgroundY.current = newY;
    if (menuOpen) {
      setMenuOpen(false);
    }
  };

  /** Отцентрировать поле на компоненте из списка (jump to). */
  const handleJumpToComponent = (comp: CircuitComponentView, index: number) => {
    const svg = connectionsSvgRef.current;
    const z = Math.max(zoomRef.current || 1, 0.01);
    let targetX = 0;
    let targetY = 0;
    if (svg) {
      const r = svg.getBoundingClientRect();
      const viewWidth = r.width / z;
      const viewHeight = r.height / z;
      const host = svg.parentElement;
      const node = host
        ? host.querySelector<HTMLElement>(`[data-ic-component-id="${index}"]`)
        : null;
      const halfW = node ? node.getBoundingClientRect().width / 2 : 0;
      const halfH = node ? node.getBoundingClientRect().height / 2 : 0;
      targetX = viewWidth / 2 - (comp.x || 0) * z - halfW;
      targetY = viewHeight / 2 - (comp.y || 0) * z - halfH;
    }
    planePanDirty.current = false;
    backgroundX.current = targetX;
    backgroundY.current = targetY;
    setScreenPanOverride({ x: targetX, y: targetY });
    setPlaneHomeNonce((n) => n + 1);
    act('move_screen', { screen_x: targetX, screen_y: targetY });
  };

  /** IE: экранные координаты → rel_x/rel_y через обратную CTM SVG (без деления на zoom-состояние). */
  const ieClientToCircuitCoords = (clientX: number, clientY: number) => {
    const svg = connectionsSvgRef.current;
    if (!svg) {
      return { rel_x: 0, rel_y: 0 };
    }
    const ctm = svg.getScreenCTM();
    if (ctm) {
      try {
        const inv = ctm.inverse();
        const pt = svg.createSVGPoint();
        pt.x = clientX;
        pt.y = clientY;
        const local = pt.matrixTransform(inv);
        return { rel_x: local.x, rel_y: local.y };
      }
      catch {
        // fall through
      }
    }
    return { rel_x: 0, rel_y: 0 };
  };

  const handleShiftPlaneMouseDown = (event: MouseEvent) => {
    if (!data.ie_circuit || data.ie_clone_copy_mode !== 'assembly') {
      return;
    }
    const { rel_x, rel_y } = ieClientToCircuitCoords(event.clientX, event.clientY);
    act('ie_place_hand_chip_at', { rel_x, rel_y });
  };

  const handleIePlaceChipCenter = () => {
    if (!data.ie_circuit || data.ie_clone_copy_mode !== 'assembly') {
      return;
    }
    const svg = connectionsSvgRef.current;
    if (!svg) {
      act('ie_place_hand_chip_at', { rel_x: 0, rel_y: 0 });
      return;
    }
    const r = svg.getBoundingClientRect();
    const { rel_x, rel_y } = ieClientToCircuitCoords(r.left + r.width / 2, r.top + r.height / 2);
    act('ie_place_hand_chip_at', { rel_x, rel_y });
  };

  const handleComponentDragStart = (e: ReactDragEvent, index: number) => {
    componentReorderSrc.current = index;
    e.dataTransfer.effectAllowed = 'move';
    e.dataTransfer.setData('text/plain', String(index));
  };

  const handleComponentDragOver = (e: ReactDragEvent, index: number) => {
    if (componentReorderSrc.current === null) {
      return;
    }
    e.preventDefault();
    e.dataTransfer.dropEffect = 'move';
    if (componentDragOver !== index) {
      setComponentDragOver(index);
    }
  };

  const handleComponentDrop = (e: ReactDragEvent, index: number) => {
    e.preventDefault();
    const from = componentReorderSrc.current;
    componentReorderSrc.current = null;
    setComponentDragOver(null);
    if (from === null || from === index) {
      return;
    }
    act('move_component_order', { from_index: from, to_index: index });
  };

  const handleComponentDragEnd = () => {
    componentReorderSrc.current = null;
    setComponentDragOver(null);
  };

  const handleNodeMouseDown = (componentId: number, event: MouseEvent) => {
    event.stopPropagation();
    const additive = event.shiftKey || event.ctrlKey || event.metaKey;
    let nextSelection: number[];
    if (additive) {
      nextSelection = selection.includes(componentId)
        ? selection.filter((id) => id !== componentId)
        : [...selection, componentId];
    }
    else if (selection.includes(componentId)) {
      nextSelection = selection;
    }
    else {
      nextSelection = [componentId];
    }
    if (!nextSelection.length) {
      setSelection([]);
      return;
    }
    const startPositions: GroupDragState['startPositions'] = {};
    for (const id of nextSelection) {
      const comp = latestComponents.current[id - 1];
      if (comp) {
        startPositions[id] = { x: comp.x || 0, y: comp.y || 0 };
      }
    }
    setSelection(nextSelection);
    setDragState({
      ids: nextSelection,
      startPositions,
      startClientX: event.clientX,
      startClientY: event.clientY,
      deltaX: 0,
      deltaY: 0,
    });
    window.addEventListener('mousemove', handleNodeDrag);
    window.addEventListener('mouseup', handleNodeDragEnd);
  };

  const buildWireConnections = (
    components: (CircuitComponentView | null)[],
    portLocations: Record<string, PortLocation>,
    selPort: SelectedPortState | null,
    dragX: number | null,
    dragY: number | null,
    zoomState: number,
  ): WireConnection[] => {
    const connections: WireConnection[] = [];

    for (const comp of components) {
      if (comp === null) {
        continue;
      }

      const inputPorts = comp.input_ports;
      for (const input of inputPorts) {
        const linked = connectedToRefList(input?.connected_to);
        for (const outputRef of linked) {
          const output_port = portLocations[outputRef];
          connections.push({
            color: (output_port && output_port.color) || 'blue',
            from: output_port,
            to: portLocations[input.ref],
            outRef: outputRef,
            inRef: input.ref,
          });
        }
      }
    }

    if (selPort) {
      const z = Math.max(zoomState || 1, 0.01);
      const isOutput = selPort.is_output;
      const portLocation = portLocations[selPort.ref];
      const svg = connectionsSvgRef.current;
      if (portLocation && svg && dragX !== null && dragY !== null) {
        const sr = svg.getBoundingClientRect();
        const mouseCoords = {
          x: (dragX - sr.left) / z,
          y: (dragY - sr.top) / z,
        };
        connections.push({
          color: (portLocation && portLocation.color) || 'blue',
          from: isOutput ? portLocation : mouseCoords,
          to: isOutput ? mouseCoords : portLocation,
          isPreview: true,
        });
      }
    }

    const fanOutOrder = new Map<string, number>();
    for (const comp of components) {
      if (!comp) {
        continue;
      }
      for (const op of comp.output_ports) {
        const targets = connectedToRefList(op?.connected_to);
        for (let ti = 0; ti < targets.length; ti++) {
          fanOutOrder.set(`${op.ref}\0${targets[ti]}`, ti);
        }
      }
    }

    connections.sort((a, b) => {
      if (a.isPreview || b.isPreview) {
        if (a.isPreview && b.isPreview) {
          return 0;
        }
        return a.isPreview ? 1 : -1;
      }
      if (!a.outRef || !b.outRef || !a.inRef || !b.inRef) {
        return 0;
      }
      if (a.outRef !== b.outRef) {
        return a.outRef < b.outRef ? -1 : 1;
      }
      const ia = fanOutOrder.get(`${a.outRef}\0${a.inRef}`) ?? 999;
      const ib = fanOutOrder.get(`${b.outRef}\0${b.inRef}`) ?? 999;
      return ia - ib;
    });

    return connections;
  };

  /** Размер видимой области в мировых единицах (не зависит от transform-scale). */
  const computeViewportSize = () => {
    const svg = connectionsSvgRef.current;
    if (svg) {
      const vw = svg.clientWidth;
      const vh = svg.clientHeight;
      if (vw > 0 && vh > 0) {
        return { vw, vh };
      }
    }
    return { vw: 0, vh: 0 };
  };

  /** Мировые границы всех узлов (замер по DOM через обратную CTM, без деления на zoom). */
  const computeComponentBounds = () => {
    const svg = connectionsSvgRef.current;
    if (!svg) {
      return null;
    }
    const host = svg.parentElement;
    if (!host) {
      return null;
    }
    let inv = null;
    const ctm = svg.getScreenCTM();
    if (ctm) {
      try {
        inv = ctm.inverse();
      }
      catch {
        inv = null;
      }
    }
    const nodes = host.querySelectorAll<HTMLElement>('[data-ic-component-id]');
    if (nodes.length === 0) {
      return null;
    }
    let minX = Infinity;
    let minY = Infinity;
    let maxX = -Infinity;
    let maxY = -Infinity;
    nodes.forEach((node) => {
      const r = node.getBoundingClientRect();
      let x0;
      let y0;
      let x1;
      let y1;
      if (inv) {
        const tl = svg.createSVGPoint();
        tl.x = r.left;
        tl.y = r.top;
        const p0 = tl.matrixTransform(inv);
        const br = svg.createSVGPoint();
        br.x = r.right;
        br.y = r.bottom;
        const p1 = br.matrixTransform(inv);
        x0 = p0.x;
        y0 = p0.y;
        x1 = p1.x;
        y1 = p1.y;
      }
      else {
        // Fallback: CTM недоступен — делим на текущий zoom (лучшее из худшего).
        const z = Math.max(zoomRef.current || 1, 0.01);
        const sr = svg.getBoundingClientRect();
        x0 = (r.left - sr.left) / z;
        y0 = (r.top - sr.top) / z;
        x1 = (r.right - sr.left) / z;
        y1 = (r.bottom - sr.top) / z;
      }
      if (x0 < minX) {
        minX = x0;
      }
      if (y0 < minY) {
        minY = y0;
      }
      if (x1 > maxX) {
        maxX = x1;
      }
      if (y1 > maxY) {
        maxY = y1;
      }
    });
    return { minX, minY, maxX, maxY };
  };

  /** Центрирует мировую точку (wx, wy) при зуме z и сохраняет якорь для миникарты. */
  const centerOnWorld = (wx: number, wy: number, z: number) => {
    const { vw, vh } = computeViewportSize();
    const targetLeft = vw / 2 - wx * z;
    const targetTop = vh / 2 - wy * z;
    backgroundX.current = targetLeft;
    backgroundY.current = targetTop;
    setZoom(z);
    setScreenPanOverride({ x: targetLeft, y: targetTop });
    setPlaneHomeNonce((n) => n + 1);
    act('move_screen', { screen_x: targetLeft, screen_y: targetTop });
  };

  /** Вписать все компоненты в видимую область (fit-to-view / «Показать всё»). */
  const fitToView = () => {
    const bounds = computeComponentBounds();
    if (!bounds) {
      return;
    }
    const { vw, vh } = computeViewportSize();
    if (vw <= 0 || vh <= 0) {
      return;
    }
    const PAD = 60;
    const w = Math.max(bounds.maxX - bounds.minX + PAD * 2, 1);
    const h = Math.max(bounds.maxY - bounds.minY + PAD * 2, 1);
    const z = Math.min(1.5, Math.max(0.1, Math.min(vw / w, vh / h)));
    const cx = (bounds.minX + bounds.maxX) / 2;
    const cy = (bounds.minY + bounds.maxY) / 2;
    centerOnWorld(cx, cy, z);
  };

  useEffect(() => {
    window.addEventListener('mousedown', handleMouseDown);
    window.addEventListener('mouseup', handleMouseUp);
    window.addEventListener('keydown', handleWindowKeyDown);
    return () => {
      window.removeEventListener('mousedown', handleMouseDown);
      window.removeEventListener('mouseup', handleMouseUp);
      window.removeEventListener('keydown', handleWindowKeyDown);
      window.removeEventListener('mousemove', handlePortDrag);
      window.removeEventListener('mouseup', handlePortRelease);
      window.removeEventListener('mousemove', handleNodeDrag);
      window.removeEventListener('mouseup', handleNodeDragEnd);
      window.removeEventListener('mousemove', handleMarqueeMove);
      window.removeEventListener('mouseup', handleMarqueeEnd);
      if (locationRaf.current !== null) {
        cancelAnimationFrame(locationRaf.current);
        locationRaf.current = null;
      }
      locationPending.current.clear();
    };
  }, [
    handleMouseDown,
    handleMouseUp,
    handleWindowKeyDown,
    handlePortDrag,
    handlePortRelease,
    handleNodeDrag,
    handleNodeDragEnd,
    handleMarqueeMove,
    handleMarqueeEnd,
  ]);

  useEffect(() => {
    if (!screenPanOverride) {
      return;
    }
    const sx = data.screen_x;
    const sy = data.screen_y;
    if (
      typeof sx === 'number'
      && typeof sy === 'number'
      && Math.abs(sx - screenPanOverride.x) < 0.01
      && Math.abs(sy - screenPanOverride.y) < 0.01
    ) {
      setScreenPanOverride(null);
    }
  }, [data.screen_x, data.screen_y, screenPanOverride]);

  const {
    circuit_on,
    display_name,
    examined_name,
    examined_desc,
    examined_notices,
    examined_rel_x,
    examined_rel_y,
    screen_x,
    screen_y,
    is_admin,
    variables,
    global_basic_types,
    ie_circuit,
    ie_clone_copy_mode,
    circuit_pulses,
    circuit_pulse_out_ref,
    circuit_pulse_in_ref,
  } = data;

  if (memoDataKey.current !== data) {
    memoDataKey.current = data;
    memoComponents.current = byondListToArray(data.components).map(
      normalizeCircuitComponent,
    );
    memoPortLabelByRef.current = buildPortLabelByRef(memoComponents.current);
    memoPulseKeys.current = buildPulseKeys(
      circuit_pulses,
      circuit_pulse_out_ref,
      circuit_pulse_in_ref,
    );
  }
  const components = memoComponents.current;
  const portLabelByRef = memoPortLabelByRef.current;
  const pulseKeys = memoPulseKeys.current;
  latestComponents.current = components;

  const ieBatteryPercent = ie_circuit && data.ie_battery_percent !== undefined
    ? data.ie_battery_percent
    : undefined;
  const ieUsedSize = ie_circuit ? data.ie_used_size : undefined;
  const ieMaxSize = ie_circuit ? data.ie_max_size : undefined;
  const ieUsedComplexity = ie_circuit ? data.ie_used_complexity : undefined;
  const ieMaxComplexity = ie_circuit ? data.ie_max_complexity : undefined;
  const circuitCellPercent = !ie_circuit ? data.circuit_cell_percent : undefined;
  const panX = screenPanOverride?.x ?? screen_x ?? 0;
  const panY = screenPanOverride?.y ?? screen_y ?? 0;
  if (!panInitialized.current) {
    panInitialized.current = true;
    backgroundX.current = panX;
    backgroundY.current = panY;
  }

  const connInputs: unknown[] = [
    components,
    locations,
    selectedPort,
    dragClientX,
    dragClientY,
  ];
  if (selectedPort) {
    connInputs.push(zoom);
  }
  const connCached = memoConnInputs.current !== null
    && memoConnInputs.current.length === connInputs.length
    && memoConnInputs.current.every((v, i) => v === connInputs[i]);
  let connections: WireConnection[];
  if (connCached && memoConnections.current !== null) {
    connections = memoConnections.current;
  }
  else {
    connections = buildWireConnections(
      components,
      locations,
      selectedPort,
      dragClientX,
      dragClientY,
      zoom,
    );
    memoConnInputs.current = connInputs;
    memoConnections.current = connections;
  }

  const componentCount = components.reduce((n, c) => n + (c ? 1 : 0), 0);
  const variableCount = variables?.length ?? 0;
  const zoomPercent = Math.round((zoom || 1) * 100);
  const filterQuery = componentsFilter.trim().toLowerCase();
  const filteredComponents = components
    .map((comp, i) => (comp ? { comp, index: i + 1 } : null))
    .filter(
      (entry): entry is { comp: CircuitComponentView; index: number } =>
        entry !== null
        && (!filterQuery
          || entry.comp.name.toLowerCase().includes(filterQuery)
          || String(entry.index).includes(filterQuery)),
    );
  /** Только корпус сборки (не одиночный чип в руках) — вставка чипа в поле. */
  const ieAssemblyUi = !!ie_circuit && ie_clone_copy_mode === 'assembly';

  return (
    <Window
      width={920}
      height={720}
      buttons={(
        <Box
          className="IntegratedCircuit__titleNameWrap"
          position="absolute"
          left={0}
          top="4px"
          height="24px">
          <Stack align="center" wrap="nowrap">
            <Stack.Item>
              <Input
                width="260px"
                maxWidth="min(100%, 320px)"
                placeholder={ie_circuit
                  ? 'Имя корпуса'
                  : 'Имя схемы'}
                value={display_name}
                onChange={(e, value) => act('set_display_name', { display_name: value })}
              />
            </Stack.Item>
            {!ie_circuit && (
              <Stack.Item>
                <Button
                  color="transparent"
                  icon="cog"
                  tooltip="Переменные и сеттеры/геттеры"
                  selected={menuOpen}
                  onClick={() => setMenuOpen((open) => !open)}
                />
              </Stack.Item>
            )}
            {!!is_admin && !ie_circuit && (
              <Stack.Item>
                <Button
                  color="transparent"
                  tooltip="Сохранить схему (JSON)"
                  onClick={() => act('save_circuit')}
                  icon="save"
                />
              </Stack.Item>
            )}
          </Stack>
        </Box>
      )}
    >
      <Window.Content
        fitted
        className="IntegratedCircuit__content">
        <Box className="IntegratedCircuit__frame">
          <CircuitToolbar
            circuitOn={circuit_on}
            componentCount={componentCount}
            variableCount={variableCount}
            zoomPercent={zoomPercent}
            showVariableChip={!ie_circuit}
            ieBatteryPercent={ieBatteryPercent}
            circuitCellPercent={circuitCellPercent}
            onEjectPowerCell={
              (ie_circuit && ieBatteryPercent !== null)
              || (!ie_circuit && circuitCellPercent !== null && circuitCellPercent !== undefined)
                ? () => act(ie_circuit ? 'ie_eject_battery' : 'eject_circuit_cell')
                : undefined
            }
            ieCloneCopyMode={ie_circuit ? ie_clone_copy_mode : null}
            ieUsedSize={ieUsedSize}
            ieMaxSize={ieMaxSize}
            ieUsedComplexity={ieUsedComplexity}
            ieMaxComplexity={ieMaxComplexity}
            onIeCloneCopy={
              ie_circuit
              && (ie_clone_copy_mode === 'assembly' || ie_clone_copy_mode === 'chip')
                ? () =>
                  act(
                    ie_clone_copy_mode === 'assembly'
                      ? 'ie_copy_assembly_code'
                      : 'ie_copy_component_code',
                  )
                : undefined
            }
            onIeClassicUi={
              ie_circuit ? () => act('ie_switch_classic_ui') : undefined
            }
            onIePlaceChipCenter={
              ieAssemblyUi ? handleIePlaceChipCenter : undefined
            }
            onFitToView={fitToView}
          />
          <Box className="IntegratedCircuit__planeHost">
            <InfinitePlane
              width="100%"
              height="100%"
              backgroundImage={resolveAsset('grid_background.png')}
              imageWidth={1200}
              onZoomChange={handleZoomChange}
              onBackgroundMoved={handleBackgroundMoved}
              initialLeft={panX}
              initialTop={panY}
              initialZoom={zoom}
              resetPanNonce={planeHomeNonce}
              onShiftPlaneMouseDown={
                ieAssemblyUi ? handleShiftPlaneMouseDown : undefined
              }
              onPlaneMouseDown={handlePlaneMouseDown}
            >
              <Connections
                connections={connections}
                svgRef={connectionsSvgRef}
                pulseKeys={pulseKeys}>
                {components.map(
                  (comp, index) =>
                    comp && (() => {
                      const componentId = index + 1;
                      const dragging = !!dragState && dragState.ids.includes(componentId);
                      const dx = dragging ? dragState.deltaX : 0;
                      const dy = dragging ? dragState.deltaY : 0;
                      return (
                        <ObjectComponent
                          key={index}
                          {...comp}
                          x={(comp.x || 0) + dx}
                          y={(comp.y || 0) + dy}
                          index={componentId}
                          circuitOn={circuit_on ?? true}
                          onPortUpdated={handlePortLocation}
                          onPortLoaded={handlePortLocation}
                          onPortMouseDown={handlePortClick}
                          onPortRightClick={handlePortRightClick}
                          onPortMouseUp={handlePortUp}
                          portLabelByRef={portLabelByRef}
                          connectSourceRef={connectSource?.ref ?? null}
                          selected={selection.includes(componentId)}
                          onNodeMouseDown={(e) => handleNodeMouseDown(componentId, e)}
                        />
                      );
                    })()
                )}
              </Connections>
            </InfinitePlane>
            {componentCount === 0 && (
              <Box className="IntegratedCircuit__emptyHint">
                <Icon name="microchip" mr={1.5} />
                {ieAssemblyUi
                  ? 'Вставьте чип из руки: «Чип сюда» или Shift+ЛКМ по полю'
                  : 'Схема пуста'}
              </Box>
            )}
            {!componentsPanelOpen && !menuOpen && (
              <Minimap
                components={components}
                backgroundXRef={backgroundX}
                backgroundYRef={backgroundY}
                zoomRef={zoomRef}
                svgRef={connectionsSvgRef}
                onCenter={centerOnWorld}
              />
            )}
            <Box
              className="IntegratedCircuit__componentsToggle"
              position="absolute"
              right="0.5rem"
              top="2rem"
              style={{ zIndex: 6 }}>
              <Button
                icon="list-ul"
                selected={componentsPanelOpen}
                color="transparent"
                tooltip="Список компонентов"
                onClick={() => setComponentsPanelOpen((open) => !open)}>
                Компоненты
              </Button>
            </Box>
            {componentsPanelOpen && (
              <Box
                className="IntegratedCircuit__componentsPanel"
                position="absolute"
                right="0"
                top="2.9rem"
                bottom="0"
                width="18rem"
                style={{ zIndex: 6 }}>
                <Section
                  title={`Компоненты (${componentCount})`}
                  fill
                  scrollable
                  buttons={(
                    <Button
                      icon="times"
                      color="transparent"
                      tooltip="Закрыть список"
                      onClick={() => setComponentsPanelOpen(false)}
                    />
                  )}>
                  <Stack vertical>
                    <Stack.Item>
                      <Input
                        fluid
                        placeholder="Поиск по имени / номеру…"
                        value={componentsFilter}
                        onChange={(e, val) => setComponentsFilter(val)}
                      />
                    </Stack.Item>
                    {filteredComponents.length === 0 && (
                      <Stack.Item>
                        <Box color="label" opacity={0.7} mt={0.5}>
                          {components.length === 0 ? 'Нет компонентов' : 'Ничего не найдено'}
                        </Box>
                      </Stack.Item>
                    )}
                    {filteredComponents.map(({ comp, index }) => (
                      <Stack.Item key={index}>
                        <Box
                          className={
                            componentDragOver === index
                              ? 'IntegratedCircuit__componentRow IntegratedCircuit__componentRow--dragOver'
                              : 'IntegratedCircuit__componentRow'
                          }
                          draggable={!filterQuery}
                          title={filterQuery ? undefined : 'Перетащите, чтобы изменить порядок'}
                          onDragStart={(e) => handleComponentDragStart(e, index)}
                          onDragOver={(e) => handleComponentDragOver(e, index)}
                          onDrop={(e) => handleComponentDrop(e, index)}
                          onDragEnd={handleComponentDragEnd}>
                          <Button
                            fluid
                            color="transparent"
                            tooltip={`Перейти к «${comp.name}»`}
                            onClick={() => handleJumpToComponent(comp, index)}>
                            <Icon
                              name="circle"
                              color={comp.recent_pulse ? '#5dff8a' : (comp.color || 'blue')}
                            />
                            {' '}
                            #{index}
                            {' '}
                            {comp.name}
                          </Button>
                        </Box>
                      </Stack.Item>
                    ))}
                  </Stack>
                </Section>
              </Box>
            )}
          </Box>
        </Box>
        {!!examined_name && (
          <CircuitInfo
            position="absolute"
            className="CircuitInfo__Examined"
            top={`${examined_rel_y}px`}
            left={`${examined_rel_x}px`}
            name={examined_name}
            desc={examined_desc}
            notices={examined_notices}
          />
        )}
        <PinEditor />
        {marquee && (
          <Box
            className="IntegratedCircuit__marquee"
            left={marquee.x0}
            top={marquee.y0}
            width={marquee.x1 - marquee.x0}
            height={marquee.y1 - marquee.y0}
          />
        )}
        {!!menuOpen && !ie_circuit && (
          <Box
            className="IntegratedCircuit__variableDock"
            position="absolute"
            bottom={0}
            left={0}
            height="50%"
            minHeight="300px"
            width="100%">
            <VariableMenu
              variables={variables}
              types={global_basic_types}
              onAddVariable={(name, type) => act('add_variable', {
                variable_name: name,
                variable_datatype: type,
              })}
              onRemoveVariable={(name) => act('remove_variable', {
                variable_name: name,
              })}
              handleAddSetter={() => act('add_setter_or_getter', {
                is_setter: true,
              })}
              handleAddGetter={() => act('add_setter_or_getter', {
                is_setter: false,
              })}
            />
          </Box>
        )}
      </Window.Content>
    </Window>
  );
};