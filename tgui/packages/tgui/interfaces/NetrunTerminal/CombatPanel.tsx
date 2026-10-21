import { useEffect, useState } from 'react';

import { useBackend } from '../../backend';
import { Box, Button, Icon } from '../../components';
import { CombatTarget, NetrunData, THEME } from './types';

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

export const CombatPanel = () => {
  const { act, data } = useBackend<NetrunData>();
  const { combat } = data;
  const [target, setTarget] = useState<string | null>(null);

  // Держим выбранную цель, пока она ещё в узле.
  const targets = combat?.targets ?? [];
  useEffect(() => {
    if (target && !targets.some((t) => t.ref === target)) {
      setTarget(null);
    }
    if (!target) {
      const hostile = targets.find((t) => t.hostile);
      if (hostile) {
        setTarget(hostile.ref);
      }
    }
  }, [targets, target]);

  if (!combat) {
    return (
      <Box color={THEME.muted} p={1} style={{ fontFamily: 'monospace' }}>
        Нет боевого контакта. Встаньте в узел с целью (или выберите доступный узел с процессом).
      </Box>
    );
  }

  const programs = combat.programs ?? [];
  return (
    <Box style={{ background: THEME.bg, border: `1px solid ${THEME.line}`, height: '100%', width: '100%', overflowY: 'auto', boxSizing: 'border-box', fontFamily: 'monospace' }} p={0.5}>
      <Box color={THEME.muted} fontSize="11px" mb={0.5}>
        <Icon name="crosshairs" mr={1} />
        Узел боя: {combat.node_name} {combat.node}
      </Box>
      {combat.self && (
        <Box mb={1} p={0.5} style={{ background: THEME.panel, border: `1px solid ${THEME.line}` }}>
          <Box color={THEME.accent}>
            Вы {combat.self.stunned ? ' · ОГЛУШЕНЫ' : ''}
          </Box>
          <IntegrityBar cur={combat.self.integrity} max={combat.self.max_integrity} />
          <Box fontSize="10px" color={THEME.muted}>
            Целостность {combat.self.integrity}/{combat.self.max_integrity}
          </Box>
        </Box>
      )}

      <Box color={THEME.muted} fontSize="10px" mb={0.5}>Процессы в узле</Box>
      {targets.length === 0 ? (
        <Box color={THEME.muted} mb={1}>Других процессов нет.</Box>
      ) : (
        targets.map((t: CombatTarget) => (
          <Box
            key={t.ref}
            mb={0.5}
            p={0.5}
            onClick={() => setTarget(t.ref)}
            style={{
              cursor: 'pointer',
              background: target === t.ref ? THEME.line : THEME.panel,
              border: `1px solid ${t.hostile ? THEME.bad : THEME.line}`,
            }}
          >
            <Box color={t.hostile ? THEME.bad : THEME.text}>
              <Icon name={t.hostile ? 'skull' : 'ghost'} mr={1} />
              {t.name}
              {t.stunned ? <Box inline ml={1} color={THEME.warn}>оглушён</Box> : null}
              {target === t.ref ? <Box inline ml={1} color={THEME.accent}>● цель</Box> : null}
            </Box>
            <IntegrityBar cur={t.integrity} max={t.max_integrity} />
            <Box fontSize="10px" color={THEME.muted}>
              {t.integrity}/{t.max_integrity}
            </Box>
          </Box>
        ))
      )}

      <Box color={THEME.muted} fontSize="10px" mt={1} mb={0.5}>Боевые программы</Box>
      {programs.length === 0 ? (
        <Box color={THEME.muted}>Нет боевых программ. Запишите их на шард или добудьте из обломков ICE.</Box>
      ) : (
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: '4px' }}>
          {programs.map((p) => {
            const onCd = p.ready_in > 0;
            const needTarget = p.needs_target && !target;
            return (
              <Button
                key={p.uid}
                icon={p.icon}
                disabled={onCd || needTarget || combat.self?.stunned}
                color={ROLE_COLORS[p.role]}
                tooltip={`${p.desc}${p.consumable ? ' (одноразовая)' : ''}${onCd ? ` · перезарядка ${p.ready_in}с` : ''}`}
                onClick={() => act('program_use', { uid: p.uid, target: p.needs_target ? target : null })}
              >
                {p.name.replace(/\.(exe|card)$/, '')}
                {onCd ? ` ${p.ready_in}s` : ''}
              </Button>
            );
          })}
        </div>
      )}
    </Box>
  );
};
