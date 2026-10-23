import type { GraphOverlay } from './graphPresentation';
import { GraphScene, PlacedNode } from './graphScene';
import { GraphViewport } from './graphViewport';
import type { PixiSurface } from './pixiSurface';
import type { NetEdge } from './types';

export type ViewportPhase = 'loading' | 'ready' | 'empty' | 'paused' | 'error';
export type ViewportStatus = { phase: ViewportPhase; message?: string };
export type ViewportHUD = { nodes: number; zoom: number };
export type ViewportHover = { address: string; x: number; y: number } | null;
export type SelectionFeedback = { phase: 'pending' | 'confirmed' | 'rejected' | 'timeout'; address: string; label: string; message: string } | null;
export type ViewportSnapshot = {
  base: GraphScene;
  scene: GraphScene;
  overlay: GraphOverlay;
  dynamicEdges: NetEdge[];
  adjacency: Map<string, Set<string>>;
  suspended: boolean;
};
type Callbacks = {
  onStatus: (status: ViewportStatus) => void;
  onHUD: (hud: ViewportHUD) => void;
  onHover: (hover: ViewportHover) => void;
  onSelect: (address: string) => void;
  onSelectionFeedback?: (feedback: SelectionFeedback) => void;
};
export type PixiSurfaceFactory = (host: HTMLElement, width: number, height: number,
  onUnavailable: () => void, options: { signal: AbortSignal; onStatus?: (status: 'ready' | 'lost') => void }) => Promise<PixiSurface | null>;

const mountSurface: PixiSurfaceFactory = async (...args) => {
  const { mountNetrunPixi } = await import('./pixiSurface');
  return mountNetrunPixi(...args);
};
const ERROR_MESSAGE = 'Не удалось запустить карту сети. Проверьте аппаратное ускорение клиента и повторите попытку.';

/** One owner for the GPU lifetime, camera and gestures; React only displays its HUD. */
export class NetworkViewportController {
  readonly camera = new GraphViewport();
  private host: HTMLElement | null = null;
  private surface: PixiSurface | null = null;
  private contextLost = false;
  private abort: AbortController | null = null;
  private generation = 0;
  private status: ViewportStatus = { phase: 'paused' };
  private observer: ResizeObserver | null = null;
  private lastBase: GraphScene | null = null;
  private lastGateways: GraphOverlay['gateways'] | null = null;
  private lastZones: GraphOverlay['apcZones'];
  private hover: ViewportHover = null;
  private hud: ViewportHUD = { nodes: -1, zoom: -1 };
  private press: { pointer: number; x: number; y: number; panX: number; panY: number; moved: boolean } | null = null;
  private fitLimit: { scene: GraphScene; zones: GraphOverlay['apcZones']; width: number; height: number; zoom: number } | null = null;
  private pendingSelection: string | null = null;
  private selectionHostAtStart: string | null = null;
  private pendingTimer: number | null = null;
  private feedbackTimer: number | null = null;

  constructor(private snapshot: ViewportSnapshot, private callbacks: Callbacks,
    private factory: PixiSurfaceFactory = mountSurface) {}

  attach(host: HTMLElement) {
    if (this.host === host) { return; }
    this.detach();
    this.host = host;
    host.addEventListener('pointerdown', this.pointerDown);
    host.addEventListener('pointermove', this.pointerMove);
    host.addEventListener('pointerup', this.pointerUp);
    host.addEventListener('pointercancel', this.cancelGesture);
    host.addEventListener('lostpointercapture', this.cancelGesture);
    host.addEventListener('pointerleave', this.pointerLeave);
    host.addEventListener('wheel', this.wheel, { passive: false });
    window.addEventListener('resize', this.resize);
    window.addEventListener('blur', this.cancelGesture);
    this.observer = typeof ResizeObserver === 'undefined' ? null : new ResizeObserver(this.resize);
    this.observer?.observe(host);
    this.status = { phase: 'paused' };
    this.update(this.snapshot);
  }

  detach() {
    const host = this.host;
    this.host = null;
    this.stopSurface();
    this.observer?.disconnect(); this.observer = null;
    window.removeEventListener('resize', this.resize);
    window.removeEventListener('blur', this.cancelGesture);
    host?.removeEventListener('pointerdown', this.pointerDown);
    host?.removeEventListener('pointermove', this.pointerMove);
    host?.removeEventListener('pointerup', this.pointerUp);
    host?.removeEventListener('pointercancel', this.cancelGesture);
    host?.removeEventListener('lostpointercapture', this.cancelGesture);
    host?.removeEventListener('pointerleave', this.pointerLeave);
    host?.removeEventListener('wheel', this.wheel);
    this.press = null;
    this.clearSelectionTimers(); this.pendingSelection = null;
  }

  update(snapshot: ViewportSnapshot) {
    const previousBase = this.snapshot.base;
    const previousZones = this.snapshot.overlay.apcZones;
    this.snapshot = snapshot;
    if (!this.host) { return; }
    if (this.pendingSelection && (snapshot.overlay.selected === this.pendingSelection
      || (snapshot.overlay.entityHost === this.pendingSelection && snapshot.overlay.entityHost !== this.selectionHostAtStart))) { this.finishSelection('confirmed'); }
    if (snapshot.suspended) {
      this.pauseSurface(); this.cancelGesture(); this.setHover(null);
      this.setStatus({ phase: 'paused' });
      return;
    }
    if (!snapshot.scene.nodes.length) {
      this.pauseSurface(); this.cancelGesture(); this.setHover(null);
      this.setStatus({ phase: 'empty' }); this.publishHUD();
      return;
    }
    if (this.hover && !snapshot.scene.byAddress.has(this.hover.address)) { this.setHover(null); }
    if (this.camera.fitting && (this.status.phase === 'paused' || this.status.phase === 'empty'
      || previousBase !== snapshot.base || previousZones !== snapshot.overlay.apcZones)) {
      this.fitCamera();
    }
    this.publishHUD();
    if (this.surface) {
      if (this.present()) {
        this.setStatus(this.contextLost ? { phase: 'loading', message: 'Восстанавливаем графику карты…' } : { phase: 'ready' });
      }
    }
    else if (this.status.phase !== 'loading' && this.status.phase !== 'error') { this.startSurface(); }
  }

  retry = () => {
    if (!this.host || this.snapshot.suspended || !this.snapshot.scene.nodes.length) { return; }
    this.stopSurface(); this.startSurface();
  };

  fit = () => {
    this.fitCamera(); this.publishCamera();
  };

  center = (address: string) => {
    const point = this.snapshot.scene.byAddress.get(address);
    if (!point) { return; }
    const { width, height } = this.size();
    this.camera.center(point, width, height); this.publishCamera();
  };

  /** This changes the marker only; controls and permissions keep confirmed server data. */
  previewSelection = (address: string) => {
    if (this.pendingSelection === address) { return; }
    this.clearSelectionTimers();
    this.pendingSelection = address;
    this.selectionHostAtStart = this.snapshot.overlay.entityHost;
    if (this.snapshot.overlay.selected === address) { this.finishSelection('confirmed'); return; }
    const label = this.snapshot.scene.byAddress.get(address)?.name || address;
    this.callbacks.onSelectionFeedback?.({ phase: 'pending', address, label, message: `Выбираем: ${label}…` });
    this.renderActors();
    this.pendingTimer = window.setTimeout(() => {
      this.pendingTimer = null;
      if (this.pendingSelection === address) { this.finishSelection('timeout'); }
    }, 4000);
  };

  rejectSelection = (message: string) => { this.finishSelection('rejected', message); };

  hit(clientX: number, clientY: number): PlacedNode | null {
    const bounds = this.host?.getBoundingClientRect();
    if (!bounds) { return null; }
    const point = this.camera.unproject(clientX - bounds.left, clientY - bounds.top);
    try {
      return this.surface?.hitTest ? this.surface.hitTest(point, this.camera.zoom)
        : this.snapshot.scene.hit(point, this.camera.zoom);
    } catch { this.fail(); return null; }
  }

  private size() { return { width: this.host?.clientWidth || 720, height: this.host?.clientHeight || 480 }; }

  private setStatus(status: ViewportStatus) {
    if (this.status.phase === status.phase && this.status.message === status.message) { return; }
    this.status = status; this.callbacks.onStatus(status);
  }

  private stopSurface() {
    this.generation++;
    this.abort?.abort(); this.abort = null;
    const surface = this.surface; this.surface = null;
    this.contextLost = false;
    this.lastBase = null; this.lastGateways = null; this.lastZones = undefined;
    try { surface?.destroy(); } catch { /* Lost contexts must still release the controller. */ }
  }

  private pauseSurface() {
    if (this.surface) { this.surface.setSuspended(true); }
    else if (this.abort) {
      this.generation++; this.abort.abort(); this.abort = null;
    }
  }

  private fail = () => {
    if (!this.host || this.snapshot.suspended) { return; }
    this.stopSurface(); this.cancelGesture(); this.setHover(null);
    this.setStatus({ phase: 'error', message: ERROR_MESSAGE });
  };

  private startSurface() {
    const host = this.host;
    if (!host) { return; }
    const generation = ++this.generation;
    const abort = new AbortController(); this.abort = abort;
    const { width, height } = this.size();
    this.setStatus({ phase: 'loading' });
    void this.factory(host, width, height, () => {
      if (generation === this.generation && !abort.signal.aborted) { this.fail(); }
    }, { signal: abort.signal, onStatus: (status) => {
      if (generation !== this.generation || abort.signal.aborted) { return; }
      this.contextLost = status === 'lost';
      if (!this.surface || this.snapshot.suspended) { return; }
      this.setStatus(status === 'lost' ? { phase: 'loading', message: 'Восстанавливаем графику карты…' } : { phase: 'ready' });
    } }).then((surface) => {
      if (abort.signal.aborted || generation !== this.generation || this.host !== host || this.snapshot.suspended) {
        surface?.destroy(); return;
      }
      if (!surface) { this.fail(); return; }
      this.abort = null;
      this.surface = surface;
      if (!this.present()) { return; }
      this.setStatus(this.contextLost ? { phase: 'loading', message: 'Восстанавливаем графику карты…' } : { phase: 'ready' });
    }).catch(() => { if (generation === this.generation && !abort.signal.aborted) { this.fail(); } });
  }

  private present(): boolean {
    const surface = this.surface;
    if (!surface || this.snapshot.suspended) { return false; }
    try {
      const { width, height } = this.size();
      surface.setSuspended(false);
      if (!surface.resize(width, height)) { this.fail(); return false; }
      const { base, scene, overlay, dynamicEdges, adjacency } = this.snapshot;
      if (base !== this.lastBase || overlay.gateways !== this.lastGateways || overlay.apcZones !== this.lastZones) {
        if (!surface.updateScene(base, overlay)) { this.fail(); return false; }
        this.lastBase = base; this.lastGateways = overlay.gateways; this.lastZones = overlay.apcZones;
      }
      surface.updateActors(scene, this.presentation(), dynamicEdges, adjacency);
      surface.updateCamera(this.camera);
      return true;
    } catch { this.fail(); return false; }
  }

  private fitCamera() {
    const { width, height } = this.size();
    this.camera.fit(this.snapshot.scene.fitPoints(this.snapshot.overlay.apcZones), width, height);
  }

  private publishHUD() {
    const hud = { nodes: this.snapshot.scene.nodes.length, zoom: Math.round(this.camera.zoom * 100) };
    if (hud.nodes === this.hud.nodes && hud.zoom === this.hud.zoom) { return; }
    this.hud = hud; this.callbacks.onHUD(hud);
  }

  private publishCamera() {
    try { this.surface?.updateCamera(this.camera); } catch { this.fail(); }
    this.publishHUD();
  }

  private presentation(): GraphOverlay {
    return { ...this.snapshot.overlay, hovered: this.hover?.address ?? null,
      selected: this.pendingSelection ?? this.snapshot.overlay.selected, selectionPending: !!this.pendingSelection };
  }

  private renderActors() {
    if (!this.surface || this.snapshot.suspended || this.status.phase !== 'ready') { return; }
    const { scene, dynamicEdges, adjacency } = this.snapshot;
    try { this.surface.updateActors(scene, this.presentation(), dynamicEdges, adjacency); }
    catch { this.fail(); }
  }

  private clearSelectionTimers() {
    if (this.pendingTimer !== null) { window.clearTimeout(this.pendingTimer); this.pendingTimer = null; }
    if (this.feedbackTimer !== null) { window.clearTimeout(this.feedbackTimer); this.feedbackTimer = null; }
  }

  private finishSelection(phase: 'confirmed' | 'rejected' | 'timeout', reason?: string) {
    const address = this.pendingSelection;
    if (!address) { return; }
    this.clearSelectionTimers(); this.pendingSelection = null;
    const label = this.snapshot.scene.byAddress.get(address)?.name || address;
    this.callbacks.onSelectionFeedback?.({ phase, address, label,
      message: reason || (phase === 'confirmed' ? `Выбран: ${label}` : 'Выбор не подтверждён. Попробуйте ещё раз.') });
    this.renderActors();
    this.feedbackTimer = window.setTimeout(() => {
      this.feedbackTimer = null; this.callbacks.onSelectionFeedback?.(null);
    }, phase === 'confirmed' ? 1600 : 5000);
  }

  private resize = () => {
    if (!this.host || this.snapshot.suspended || this.status.phase === 'empty') { return; }
    if (this.camera.fitting) { this.fitCamera(); }
    this.present(); this.publishHUD();
  };

  private setHover(hover: ViewportHover) {
    if (this.hover?.address === hover?.address && this.hover?.x === hover?.x && this.hover?.y === hover?.y) { return; }
    const changedNode = this.hover?.address !== hover?.address;
    this.hover = hover; this.callbacks.onHover(hover);
    if (changedNode && this.surface && !this.snapshot.suspended && this.status.phase === 'ready') {
      this.renderActors();
    }
  }

  private pointerDown = (event: PointerEvent) => {
    if (this.press || event.button !== 0 || this.snapshot.suspended || this.status.phase !== 'ready'
      || (event.target instanceof Element && event.target.closest('[data-net-overlay]'))) { return; }
    this.press = { pointer: event.pointerId, x: event.clientX, y: event.clientY,
      panX: this.camera.x, panY: this.camera.y, moved: false };
    this.host?.focus();
    try { this.host?.setPointerCapture?.(event.pointerId); } catch { /* Pointer may already have been released. */ }
  };

  private pointerMove = (event: PointerEvent) => {
    if (this.status.phase !== 'ready' || this.snapshot.suspended) { return; }
    const press = this.press;
    if (press) {
      if (press.pointer !== event.pointerId) { return; }
      const dx = event.clientX - press.x, dy = event.clientY - press.y;
      if (dx * dx + dy * dy > 16) { press.moved = true; }
      if (press.moved) { this.camera.pan(press.panX + dx, press.panY + dy); this.setHover(null); this.publishCamera(); }
      return;
    }
    const node = this.hit(event.clientX, event.clientY), bounds = this.host?.getBoundingClientRect();
    this.setHover(node && bounds ? { address: node.address, x: event.clientX - bounds.left, y: event.clientY - bounds.top } : null);
  };

  private pointerUp = (event: PointerEvent) => {
    const press = this.press;
    if (!press || press.pointer !== event.pointerId) { return; }
    this.press = null;
    if (!press.moved) {
      const node = this.hit(event.clientX, event.clientY);
      if (node) { this.previewSelection(node.address); this.callbacks.onSelect(node.address); }
    }
  };

  private cancelGesture = () => {
    const press = this.press; this.press = null;
    if (press) { try { this.host?.releasePointerCapture?.(press.pointer); } catch { /* The browser may have cancelled capture already. */ } }
  };
  private pointerLeave = () => { this.setHover(null); };

  private wheel = (event: WheelEvent) => {
    if (event.ctrlKey || event.metaKey || this.snapshot.suspended || this.status.phase !== 'ready'
      || (event.target instanceof Element && event.target.closest('[data-net-overlay]'))) { return; }
    event.preventDefault(); this.setHover(null);
    const bounds = this.host?.getBoundingClientRect();
    if (!bounds) { return; }
    const dimensions = this.size();
    let limit = this.fitLimit;
    if (!limit || limit.scene !== this.snapshot.scene || limit.zones !== this.snapshot.overlay.apcZones
      || limit.width !== dimensions.width || limit.height !== dimensions.height) {
      const fitted = new GraphViewport(); fitted.fit(this.snapshot.scene.fitPoints(this.snapshot.overlay.apcZones), dimensions.width, dimensions.height);
      limit = this.fitLimit = { scene: this.snapshot.scene, zones: this.snapshot.overlay.apcZones, ...dimensions, zoom: fitted.zoom };
    }
    const delta = event.deltaY * (event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? dimensions.height : 1);
    this.camera.zoomAt(event.clientX - bounds.left, event.clientY - bounds.top, delta, limit.zoom);
    this.publishCamera();
  };
}
