import { CSSProperties, memo, useEffect, useState } from 'react';

import { Box, Button, Icon } from '../../components';
import { ActionTooltip } from './CommandTooltip';
import { EntityAvatar } from './EntityAvatar';
import { BotAvatar, botKindLabel, factionLabel } from './EntityContacts';
import {
  CombatTarget,
  FACTION_COLORS,
  FORTRESS_MODULE_ICONS,
  FORTRESS_MODULE_NAMES,
  IncomingProgram,
  NetrunData,
  THEME,
} from './types';
import { useNetrunBackend as useBackend } from './useNetrunBackend';

const ROLE_COLORS: Record<string, string> = {
  attack: THEME.bad,
  stun: THEME.warn,
  shield: THEME.accent,
  repair: THEME.good,
  purge: THEME.warn,
};

/** Slim gauge shared by integrity, memory and fortress slots. Integrity is green when
 * full; usage warns as it fills. A zero maximum with content reads as full. */
export const Meter = (props: {
  value: number;
  max: number;
  label: string;
  tone?: 'integrity' | 'usage';
  color?: string;
  height?: number;
  style?: CSSProperties;
}) => {
  const { value, max, tone = 'integrity', height = 6 } = props;
  const ratio = max > 0 ? Math.max(0, Math.min(1, value / max)) : value > 0 ? 1 : 0;
  const color = props.color || (tone === 'usage'
    ? ratio >= 0.95 ? THEME.bad : ratio >= 0.75 ? THEME.warn : THEME.accent
    : ratio > 0.5 ? THEME.good : ratio > 0.25 ? THEME.warn : THEME.bad);
  return (
    <div role="meter" aria-label={props.label} aria-valuemin={0} aria-valuemax={Math.max(0, max)}
      aria-valuenow={value} aria-valuetext={`${value}/${max}`} title={`${props.label}: ${value}/${max}`}
      style={{ height: `${height}px`, background: THEME.line, borderRadius: `${height / 2}px`, overflow: 'hidden', ...props.style }}>
      <div style={{ height: '100%', width: `${ratio * 100}%`, background: color, transition: 'width 0.3s' }} />
    </div>
  );
};

export const IntegrityBar = (props: { cur: number; max: number; label?: string }) => (
  <Meter value={props.cur} max={props.max} label={props.label || 'Целостность'} style={{ marginTop: '0.5rem' }} />
);

/** Bots and fortress modules carry their archetype and allegiance on the card. */
const TargetIcon = ({ target }: { target: CombatTarget }) => {
  switch (target.kind) {
    case 'entity':
      return <EntityAvatar avatar={target.persona?.avatar} accent={target.persona?.accent} size={30} />;
    case 'bot':
      return <BotAvatar kind={target.bot_kind} faction={target.faction} size={30} />;
    case 'fortress':
      return (<Icon name={FORTRESS_MODULE_ICONS[target.module ?? ''] || 'chess-rook'} mr={1}
        color={FACTION_COLORS[target.faction ?? ''] || THEME.muted} />);
    default:
      return <Icon name="skull" mr={1} />;
  }
};

const targetRole = (target: CombatTarget) => {
  if (target.kind === 'bot') {
    return [botKindLabel(target.bot_kind), factionLabel('bot', target.faction)].filter(Boolean).join(' · ');
  }
  if (target.kind === 'fortress') {
    return [FORTRESS_MODULE_NAMES[target.module ?? ''] || 'Модуль крепости', factionLabel('fortress', target.faction)]
      .filter(Boolean).join(' · ');
  }
  return null;
};

const TargetCard = (props: {
  target: CombatTarget;
  selected: boolean;
  localNode: string | null;
  onSelect: (ref: string) => void;
}) => {
  const { target: t, selected, localNode, onSelect } = props;
  const role = targetRole(t);
  // Outer works of a neighbouring fortress are engaged across the link.
  const siege = t.kind === 'fortress' && !!t.node && !!localNode && t.node !== localNode;
  return (
    <Box
      className="netrun-combat-target"
      data-net-target={t.kind}
      mb={0.5}
      p={1}
      onClick={() => !t.unavailable_reason && onSelect(t.ref)}
      style={{
        cursor: t.unavailable_reason ? 'default' : 'pointer',
        background: selected ? THEME.line : THEME.panel,
        border: `1px solid ${selected ? THEME.accent : t.hostile ? THEME.bad : THEME.line}`,
        borderRadius: '8px',
      }}
    >
      <Box color={t.hostile ? THEME.bad : THEME.text}>
        <TargetIcon target={t} />
        {t.name}
        {t.stunned ? <Box inline ml={1} color={THEME.warn}>оглушён</Box> : null}
        {t.shielded ? <Box inline ml={1} color={THEME.accent}>щит</Box> : null}
        {siege ? <Box inline ml={1} color={THEME.warn}>осада</Box> : null}
        {selected ? <Box inline ml={1} color={THEME.accent}>● цель</Box> : null}
      </Box>
      {!!role && <Box fontSize="11px" color={FACTION_COLORS[t.faction ?? ''] || THEME.muted}>{role}</Box>}
      {siege && (
        <Box fontSize="11px" color={THEME.muted}>
          Укрепления соседнего узла: удар идёт через канал осады.
        </Box>
      )}
      {!!t.persona?.tagline && <Box className="netrun-contact-tagline">{t.persona.tagline}</Box>}
      {!!t.node && <Box color={THEME.muted} fontSize="10px">{t.node_name} {t.node}</Box>}
      {!!t.unavailable_reason && <Box color={THEME.warn} fontSize="11px">{t.unavailable_reason}</Box>}
      <IntegrityBar cur={t.integrity} max={t.max_integrity} label={`Целостность ${t.name}`} />
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
  );
};

const incomingEffect = (attack: IncomingProgram) => {
  switch (attack.role) {
    case 'trace': return `+${attack.power}% трассировки`;
    case 'stun': return `${attack.power / 10} с оглушения`;
    case 'attack': return `${attack.power} урона до щита`;
    default: return `сила ${attack.power}`;
  }
};

const incomingAdvice = (role: string, compact = false) => {
  switch (role) {
    case 'trace': return compact
      ? 'Прервите взлом или оглушите ICE.'
      : 'Прервите взлом или оглушите ICE, чтобы сорвать трассировку. Щит не скрывает трассировку.';
    case 'stun': return compact
      ? 'Оглушите ICE или выйдите из узла.'
      : 'Оглушите ICE или выйдите из узла, чтобы сорвать оглушение. Щит не защищает от оглушения.';
    case 'attack': return compact
      ? 'Включите щит, оглушите ICE или выйдите из узла.'
      : 'Щит снижает урон. Оглушите ICE или выйдите из узла, чтобы сорвать атаку.';
    default: return 'Проверьте программу противника в боевой панели.';
  }
};

const incomingSummary = (attack: IncomingProgram) =>
  `${attack.source} готовит ${attack.name} · ${incomingEffect(attack)} · через ${attack.remaining} с`;

/** Shared warning for every workspace, including a running breach puzzle. */
const IncomingAttacksView = (props: { onCombat: () => void; compact?: boolean }) => {
  const { act, data } = useBackend<NetrunData>(['combat', 'breach']);
  const incoming = data.combat?.incoming ?? [];
  if (!incoming.length) { return null; }
  if (props.compact) {
    const next = incoming.reduce((soonest, attack) => attack.remaining < soonest.remaining ? attack : soonest);
    return (
      <Box role="alert" style={{ flex: '1 1 auto', minWidth: 0, height: '100%', boxSizing: 'border-box', padding: '1px 5px',
        display: 'flex', alignItems: 'center', gap: '6px', border: `1px solid ${THEME.bad}`, background: THEME.bg }}>
        <Box title={incoming.map((attack) => `${incomingSummary(attack)}\n${incomingAdvice(attack.role)}`).join('\n')}
          style={{ flex: '1 1 auto', minWidth: 0, overflow: 'hidden', fontSize: '11px', lineHeight: '13px' }}>
          <Box color={THEME.bad} bold style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
            {incomingEffect(next)} · через {next.remaining} с · {next.source} готовит {next.name}{incoming.length > 1 ? ` · угроз: ${incoming.length}` : ''}
          </Box>
          <Box style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{incomingAdvice(next.role, true)}</Box>
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
          {incomingSummary(attack)}
        </Box>
      ))}
      {Array.from(new Set(incoming.map((attack) => attack.role))).map((role) => (
        <Box key={role} fontSize="11px">{incomingAdvice(role)}</Box>
      ))}
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
  // Fortress modules are never picked automatically: a siege, like an attack on your own
  // or the station's works, starts with a deliberate selection.
  const targets = combat?.targets ?? [];
  useEffect(() => {
    const usable = targets.find((t) => t.ref === target && !t.unavailable_reason)
      ?? targets.find((t) => t.hostile && t.kind !== 'fortress' && !t.unavailable_reason);
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
  const actionReadyIn = combat.action_ready_in ?? 0;
  const actionBlockReasons = [
    combat.self?.stunned ? 'Вы оглушены: дождитесь окончания оглушения.' : null,
    data.locked > 0 ? `Терминал заблокирован: ещё ${data.locked} с.` : null,
    actionReadyIn > 0 ? `Общая пауза запуска: ещё ${actionReadyIn} с.` : null,
  ].filter((reason): reason is string => !!reason);
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
          <TargetCard key={t.ref} target={t} selected={target === t.ref} localNode={combat.node} onSelect={setTarget} />
        ))
      )}

      </div>
      <Box color={THEME.muted} fontSize="12px" mt={2} mb={1}>Боевые программы</Box>
      {!!actionBlockReasons.length && (
        <Box role="status" color={THEME.warn} fontSize="11px" mb={1}>
          {actionBlockReasons.map((reason) => <Box key={reason}>{reason}</Box>)}
        </Box>
      )}
      {programs.length === 0 ? (
        <Box color={THEME.muted}>Нет боевых программ. Запишите их на шард или добудьте из обломков ICE.</Box>
      ) : (
        <div className="netrun-combat-programs" style={{ display: 'flex', flexWrap: 'wrap', gap: '6px' }}>
          {programs.map((p) => {
            const onCd = p.ready_in > 0;
            const needTarget = p.needs_target && (!selectedTarget || !!selectedTarget.unavailable_reason);
            const blockReasons = [
              ...actionBlockReasons,
              p.unavailable_reason,
              onCd ? `Перезарядка: ещё ${p.ready_in} с.` : null,
              needTarget ? 'Сначала выберите доступную цель.' : null,
            ].filter((reason): reason is string => !!reason);
            return (
              <Button
                key={p.uid}
                icon={p.icon}
                disabled={blockReasons.length > 0}
                style={{ background: THEME.panel, border: `1px solid ${ROLE_COLORS[p.role] || THEME.line}`,
                  minWidth: '138px', maxWidth: '260px', minHeight: '40px', borderRadius: '7px', whiteSpace: 'normal' }}
                tooltip={<ActionTooltip name={p.name} id={p.id} icon={p.icon} description={p.desc}
                  facts={[
                    { label: 'Сила', value: String(p.power) },
                    { label: 'Перезарядка', value: onCd ? `Ещё ${p.ready_in} с` : `${p.cooldown} с`, warning: onCd },
                    { label: 'Файл', value: p.consumable ? 'Одноразовый' : 'Многоразовый' },
                    { label: 'Цель', value: p.needs_target ? 'Процесс в одном узле' : 'Собственная сущность' },
                  ]}
                  notices={blockReasons.map((text) => ({ text }))} />}
                onClick={() => act('program_use', { uid: p.uid, target: p.needs_target ? target : null })}
              >
                <Box style={{ minWidth: 0 }}>
                  <Box>{p.name.replace(/\.(exe|card)$/, '')}</Box>
                  {!!blockReasons.length && <Box fontSize="10px" color={THEME.warn} style={{ lineHeight: '14px' }}>{blockReasons[0]}</Box>}
                </Box>
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
