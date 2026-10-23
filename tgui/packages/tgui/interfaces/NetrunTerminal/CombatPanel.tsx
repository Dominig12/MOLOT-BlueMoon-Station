import { memo, useEffect, useState } from 'react';

import { Box, Button, Icon } from '../../components';
import { CombatTarget, NetrunData, THEME } from './types';
import { useNetrunBackend as useBackend } from './useNetrunBackend';

const ROLE_COLORS: Record<string, string> = {
  attack: THEME.bad,
  stun: THEME.warn,
  shield: THEME.accent,
  repair: THEME.good,
  purge: THEME.warn,
};

const IntegrityBar = (props: { cur: number; max: number }) => {
  const ratio = props.max ? Math.max(0, props.cur / props.max) : 0;
  return (
    <Box mt={0.5} style={{ height: '6px', background: THEME.line }}>
      <Box
        style={{
          height: '6px',
          width: `${ratio * 100}%`,
          background: ratio > 0.5 ? THEME.good : ratio > 0.25 ? THEME.warn : THEME.bad,
          transition: 'width 0.3s',
        }}
      />
    </Box>
  );
};

/** Shared warning for every workspace, including a running breach puzzle. */
const IncomingAttacksView = (props: { onCombat: () => void; compact?: boolean }) => {
  const { act, data } = useBackend<NetrunData>(['combat', 'breach']);
  const incoming = data.combat?.incoming ?? [];
  if (!incoming.length) { return null; }
  if (props.compact) {
    const next = incoming.reduce((soonest, attack) => attack.remaining < soonest.remaining ? attack : soonest);
    return (
      <Box role="alert" p={0.5} style={{ flex: '1 1 auto', minWidth: 0, height: '100%', boxSizing: 'border-box',
        display: 'flex', alignItems: 'center', gap: '6px', border: `1px solid ${THEME.bad}`, background: THEME.bg }}>
        <Box color={THEME.bad} bold title={incoming.map((attack) => `${attack.source} готовит ${attack.name} · через ${attack.remaining} с`).join('\n')}
          style={{ flex: '1 1 auto', minWidth: 0, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', fontSize: '11px' }}>
          {next.source} готовит {next.name} · через {next.remaining} с{incoming.length > 1 ? ` · атак: ${incoming.length}` : ''}
        </Box>
        <Button compact icon="crosshairs" content="Открыть бой" style={{ flexShrink: 0 }} onClick={props.onCombat} />
        {!!data.breach && <Button compact icon="stop" content="Прервать взлом" style={{ flexShrink: 0 }} onClick={() => act('breach_abort')} />}
      </Box>
    );
  }
  return (
    <Box p={1} mb={0.5} role="alert" style={{ border: `2px solid ${THEME.bad}`, background: THEME.bg }}>
      {incoming.map((attack, index) => (
        <Box key={`${attack.source_ref ?? attack.source}-${attack.name}-${index}`} color={THEME.bad} bold>
          {attack.source} готовит {attack.name} · {attack.role === 'stun' ? `${attack.power / 10} с оглушения` : `${attack.power} ${attack.role === 'trace' ? 'трассировки' : 'урона'}`} · через {attack.remaining} с
        </Box>
      ))}
      {incoming.some((attack) => attack.role !== 'trace') && <Box fontSize="11px">Щит снижает урон. Оглушение ICE или выход из узла срывает его атаку.</Box>}
      {incoming.some((attack) => attack.role === 'trace') && <Box fontSize="11px">Чтобы сорвать trace.exe, прервите взлом или оглушите ICE. Щит не скрывает трассировку.</Box>}
      <Button icon="crosshairs" content="Открыть бой" onClick={props.onCombat} />
      {!!data.breach && <Button icon="stop" content="Прервать взлом" onClick={() => act('breach_abort')} />}
    </Box>
  );
};

const CombatPanelView = () => {
  const { act, data } = useBackend<NetrunData>(['combat', 'locked']);
  const { combat } = data;
  const [target, setTarget] = useState<string | null>(null);

  // Preserve a usable selection and replace removed or disconnected targets in one update.
  const targets = combat?.targets ?? [];
  useEffect(() => {
    const usable = targets.find((t) => t.ref === target && !t.unavailable_reason)
      ?? targets.find((t) => t.hostile && !t.unavailable_reason);
    setTarget(usable?.ref ?? null);
  }, [targets, target]);

  if (!combat) {
    return (
      <Box color={THEME.muted} p={1} style={{ fontFamily: 'monospace' }}>
        Нет боевого контакта. Встаньте в узел с целью (или выберите доступный узел с процессом).
      </Box>
    );
  }

  const programs = combat.programs ?? [];
  const selectedTarget = targets.find((t) => t.ref === target);
  return (
    <Box className="netrun-combat-panel" style={{ background: THEME.bg, border: `1px solid ${THEME.line}`, height: '100%', width: '100%', overflowY: 'auto', boxSizing: 'border-box', fontFamily: 'monospace' }} p={1}>
      <div className="netrun-combat-content">
      <Box color={THEME.muted} fontSize="12px" mb={1}>
        <Icon name="crosshairs" mr={1} />
        {combat.node ? <>Узел боя: {combat.node_name} {combat.node}</> : 'Ответный бой'}
      </Box>
      {!!combat.self && (
        <Box mb={1} p={1} className="netrun-self-panel" style={{ background: THEME.panel, border: `1px solid ${THEME.line}`, borderRadius: '8px' }}>
          <Box color={THEME.accent}>
            Вы {combat.self.stunned ? ' · ОГЛУШЕНЫ' : ''}{combat.self.shielded ? ' · ЩИТ АКТИВЕН' : ''}
          </Box>
          <IntegrityBar cur={combat.self.integrity} max={combat.self.max_integrity} />
          <Box fontSize="10px" color={THEME.muted}>
            Целостность {combat.self.integrity}/{combat.self.max_integrity}
          </Box>
        </Box>
      )}

      <Box color={THEME.muted} fontSize="12px" mb={1}>Цели и процессы</Box>
      <div className="netrun-combat-targets">
      {targets.length === 0 ? (
        <Box color={THEME.muted} mb={1}>Других процессов нет.</Box>
      ) : (
        targets.map((t: CombatTarget) => (
          <Box
            key={t.ref}
            className="netrun-combat-target"
            mb={0.5}
            p={1}
            onClick={() => !t.unavailable_reason && setTarget(t.ref)}
            style={{
              cursor: t.unavailable_reason ? 'default' : 'pointer',
              background: target === t.ref ? THEME.line : THEME.panel,
              border: `1px solid ${target === t.ref ? THEME.accent : t.hostile ? THEME.bad : THEME.line}`,
              borderRadius: '8px',
            }}
          >
            <Box color={t.hostile ? THEME.bad : THEME.text}>
              <Icon name={t.hostile ? 'skull' : 'ghost'} mr={1} />
              {t.name}
              {t.stunned ? <Box inline ml={1} color={THEME.warn}>оглушён</Box> : null}
              {t.shielded ? <Box inline ml={1} color={THEME.accent}>щит</Box> : null}
              {target === t.ref ? <Box inline ml={1} color={THEME.accent}>● цель</Box> : null}
            </Box>
            {!!t.node && <Box color={THEME.muted} fontSize="10px">{t.node_name} {t.node}</Box>}
            {!!t.unavailable_reason && <Box color={THEME.warn} fontSize="11px">{t.unavailable_reason}</Box>}
            <IntegrityBar cur={t.integrity} max={t.max_integrity} />
            <Box fontSize="10px" color={THEME.muted}>
              {t.integrity}/{t.max_integrity}
            </Box>
            {!!t.casting && <Box bold color={THEME.bad}>Готовит {t.casting.name}: {t.casting.remaining} с</Box>}
            {t.programs?.map((p) => (
              <Box key={p.name} fontSize="11px" color={p.ready_in ? THEME.muted : THEME.warn}
                title={`${p.desc} · сила ${p.power} · подготовка ${p.windup} с · кулдаун ${p.cooldown} с`}>
                {p.name}: {p.ready_in > 0 ? `перезарядка ${p.ready_in} с` : 'готова'}
              </Box>
            ))}
          </Box>
        ))
      )}

      </div>
      <Box color={THEME.muted} fontSize="12px" mt={2} mb={1}>Боевые программы</Box>
      {programs.length === 0 ? (
        <Box color={THEME.muted}>Нет боевых программ. Запишите их на шард или добудьте из обломков ICE.</Box>
      ) : (
        <div className="netrun-combat-programs" style={{ display: 'flex', flexWrap: 'wrap', gap: '6px' }}>
          {programs.map((p) => {
            const onCd = p.ready_in > 0;
            const needTarget = p.needs_target && (!selectedTarget || !!selectedTarget.unavailable_reason);
            return (
              <Button
                key={p.uid}
                icon={p.icon}
                disabled={onCd || needTarget || !!p.unavailable_reason || combat.self?.stunned || data.locked > 0}
                style={{ background: THEME.panel, border: `1px solid ${ROLE_COLORS[p.role] || THEME.line}`,
                  minWidth: '138px', minHeight: '40px', borderRadius: '7px' }}
                tooltip={`${p.desc}${p.consumable ? ' (одноразовая)' : ''}${p.unavailable_reason ? ` · ${p.unavailable_reason}` : ''}${onCd ? ` · перезарядка ${p.ready_in}с` : ''}`}
                onClick={() => act('program_use', { uid: p.uid, target: p.needs_target ? target : null })}
              >
                {p.name.replace(/\.(exe|card)$/, '')}
                {onCd ? ` ${p.ready_in}s` : ''}
              </Button>
            );
          })}
        </div>
      )}
      {!!combat.loot?.length && (
        <Box mt={1} p={0.5} style={{ border: `1px solid ${THEME.good}` }}>
          <Box bold color={THEME.good}>Добыча в узле</Box>
          {combat.loot.map((file) => (
            <Box key={file.uid}>
              {file.name} · {file.size} яч.
              <Button ml={1} icon="download" content="Забрать" disabled={combat.self?.stunned || data.locked > 0}
                onClick={() => act('recover_salvage', { uid: file.uid })} />
            </Box>
          ))}
        </Box>
      )}
      </div>
    </Box>
  );
};

export const IncomingAttacks = memo(IncomingAttacksView);

export const CombatPanel = memo(CombatPanelView);
