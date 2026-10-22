import { memo } from 'react';

import { PlacedNode } from './graphScene';
import { GraphPoint } from './mapLayout';
import { NetEvent } from './types';

/**
 * Reactive DOM layer drawn over the static canvas graph. It renders only the moving/volatile
 * things - resident processes (entities), hostile ICE and event ripples - so their frequent
 * updates re-render a handful of memoized DOM nodes instead of repainting the whole canvas.
 */

const ACTOR_STYLE = `
@keyframes netrun-ice-ring { 0%,100% { transform: translate(-50%,-50%) scale(1); opacity: .85; } 50% { transform: translate(-50%,-50%) scale(1.3); opacity: .35; } }
@keyframes netrun-ripple { from { transform: translate(-50%,-50%) scale(.5); opacity: .75; } to { transform: translate(-50%,-50%) scale(2); opacity: 0; } }
.netrun-actor { position: absolute; transform: translate(-50%,-50%); pointer-events: none; will-change: transform; }
.netrun-ice-ring { position: absolute; left: 50%; top: 50%; width: 42px; height: 42px; margin: -21px 0 0 -21px; border-radius: 50%; border: 2px solid #e9545f; animation: netrun-ice-ring 1.6s ease-in-out infinite; }
.netrun-badge { position: absolute; display: flex; align-items: center; justify-content: center; min-width: 14px; height: 14px; padding: 0 3px; border-radius: 8px; font: 700 10px/14px monospace; box-shadow: 0 1px 3px rgba(0,0,0,.5); }
.netrun-ripple { position: absolute; left: 50%; top: 50%; width: 46px; height: 46px; margin: -23px 0 0 -23px; border-radius: 50%; border: 2px solid; }
`;

type ActorProps = { node: PlacedNode; x: number; y: number };

/** One node's moving occupants. Memoized: re-renders only when its own data or screen spot moves. */
const Actor = memo((props: ActorProps) => {
  const { node, x, y } = props;
  return (
    <div className="netrun-actor" style={{ left: `${x}px`, top: `${y}px` }}>
      {!!node.ice && <div className="netrun-ice-ring" />}
      {!!node.ice && (
        <div className="netrun-badge" style={{ left: '8px', top: '-20px', background: '#ff6470', color: '#1a0708' }}>
          {node.ice}
        </div>
      )}
      {!!node.entities && (
        <div className="netrun-badge" style={{ right: '8px', top: '-20px', background: '#f19bdc', color: '#2a0f24' }}>
          {node.entities}
        </div>
      )}
    </div>
  );
});

type Props = {
  actors: PlacedNode[];
  events: NetEvent[];
  points: Map<string, GraphPoint | undefined>;
  vx: number; vy: number; vzoom: number;
  width: number; height: number;
};

export const ActorLayer = memo((props: Props) => {
  const { actors, events, points, vx, vy, vzoom, width, height } = props;
  const project = (point: GraphPoint) => ({ px: point.px * vzoom + vx, py: point.py * vzoom + vy });
  const onScreen = (px: number, py: number) => px >= -40 && px <= width + 40 && py >= -40 && py <= height + 40;
  return (
    <div aria-hidden="true" data-net-actors style={{ position: 'absolute', inset: 0, overflow: 'hidden', pointerEvents: 'none', zIndex: 4 }}>
      <style>{ACTOR_STYLE}</style>
      {events.map((event) => {
        if (event.age >= 4) { return null; }
        const anchor = points.get(event.to) || points.get(event.from);
        if (!anchor) { return null; }
        const spot = project(anchor);
        if (!onScreen(spot.px, spot.py)) { return null; }
        const color = event.kind === 'trace' ? '#f56670' : event.kind === 'purge' ? '#ff6470' : '#ffc26b';
        return (
          <div key={`ev:${event.kind}:${event.from}:${event.to}`} className="netrun-actor" style={{ left: `${spot.px}px`, top: `${spot.py}px` }}>
            <div className="netrun-ripple" style={{ borderColor: color, animation: `netrun-ripple ${Math.max(0.6, 4 - event.age)}s ease-out forwards` }} />
          </div>
        );
      })}
      {actors.map((node) => {
        const spot = project(node);
        if (!onScreen(spot.px, spot.py)) { return null; }
        return <Actor key={node.address} node={node} x={spot.px} y={spot.py} />;
      })}
    </div>
  );
});
