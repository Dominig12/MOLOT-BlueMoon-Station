import { useState } from 'react';

import { Box, Button, Icon } from '../../components';
import { EntityAvatar } from './EntityAvatar';
import { BOT_ICONS, BOT_NAMES, EntityContact, FACTION_COLORS, IceKind, THEME } from './types';
import { useNetrunBackend as useBackend } from './useNetrunBackend';

const FACTION_LABELS: Record<'bot' | 'fortress', Record<string, string>> = {
  bot: { station: 'станция', owner: 'агент', rogue: 'дикий' },
  fortress: { station: 'станция', owner: 'частная', rogue: 'подпольная' },
};

/** Allegiance wording differs for processes and structures. */
export const factionLabel = (context: 'bot' | 'fortress', faction?: string | null) =>
  (faction && FACTION_LABELS[context][faction]) || null;

export const botKindLabel = (kind?: string | null) => BOT_NAMES[kind ?? ''] || 'Автономный процесс';

export const BLACK_ICE_COLOR = '#dba0ff';
export const iceKindLabel = (kind?: IceKind) => kind === 'black' ? 'BLACK ICE · нелегальный'
  : `ICE${kind === 'hunter' ? ' · охотник' : kind === 'sentry' ? ' · сторож' : ''}`;
export const IceAvatar = ({ kind, size = 28 }: { kind?: IceKind; size?: number }) => (
  <span className="netrun-avatar" role="img" aria-label={iceKindLabel(kind)}
    style={{ color: kind === 'black' ? BLACK_ICE_COLOR : THEME.bad, width: size, height: size, fontSize: `${Math.round(size / 2)}px`,
      background: kind === 'black' ? '#271332' : undefined }}>
    <Icon name={kind === 'black' ? 'skull-crossbones' : 'shield-halved'} style={{ margin: 0 }} />
  </span>
);
export const BlackIceWarning = () => (
  <Box mt={0.5} color={BLACK_ICE_COLOR} fontSize="11px">
    <Icon name="triangle-exclamation" mr={0.5} />
    Нелегальный BLACK ICE: нейрообратная связь может повредить телу при нейроподключении.
  </Box>
);

/** Archetype pictogram framed in the faction colour (contacts, combat, agents). */
export const BotAvatar = (props: { kind?: string | null; faction?: string | null; size?: number }) => {
  const { kind, faction, size = 28 } = props;
  return (
    <span className="netrun-avatar" role="img" aria-label={`Бот: ${botKindLabel(kind)}`}
      style={{ color: FACTION_COLORS[faction ?? ''] || THEME.muted, width: size, height: size,
        fontSize: `${Math.round(size / 2)}px` }}>
      <Icon name={BOT_ICONS[kind ?? ''] || 'robot'} style={{ margin: 0 }} />
    </span>
  );
};

const contactKind = (contact: EntityContact) => {
  if (contact.kind === 'ice') {
    return iceKindLabel(contact.ice_kind);
  }
  if (contact.kind === 'bot') {
    return [botKindLabel(contact.bot_kind), factionLabel('bot', contact.faction)].filter(Boolean).join(' · ');
  }
  return 'Сущность';
};

export const EntityContacts = (props: {
  address: string;
  contacts?: EntityContact[];
  pending: boolean;
  localEntity: boolean;
}) => {
  const { act } = useBackend([]);
  if (!props.contacts?.length) { return null; }
  return (
    <Box mt={2}>
      <Box bold mb={0.5}>Процессы на узле</Box>
      {props.contacts.map((contact) => (
        <ContactCard key={`${props.address}:${contact.ref}`} contact={contact} pending={props.pending} />
      ))}
      {props.localEntity && props.contacts.some((contact) => !contact.self) && (
        <Button icon="crosshairs" content="Открыть бой" disabled={props.pending}
          onClick={() => act('workspace_view', { page: 'combat' })} />
      )}
    </Box>
  );
};

const ContactCard = (props: { contact: EntityContact; pending: boolean }) => {
  const { act } = useBackend([]);
  const { contact, pending } = props;
  const [message, setMessage] = useState('');
  const canMessage = !pending && contact.can_message;
  const bot = contact.kind === 'bot';
  const blackIce = contact.kind === 'ice' && contact.ice_kind === 'black';
  const accent = blackIce ? BLACK_ICE_COLOR : bot ? FACTION_COLORS[contact.faction ?? ''] : undefined;
  const send = () => {
    const text = message.trim();
    if (!canMessage || !text) { return; }
    act('entity_message', { ref: contact.ref, text });
    setMessage('');
  };
  return (
    <Box p={1} mb={0.5} data-net-contact={contact.kind}
      style={{ background: THEME.bg, border: `1px solid ${accent || THEME.line}` }}>
      <Box bold color={accent}>
        {contact.kind === 'entity' ? <EntityAvatar avatar={contact.persona?.avatar} accent={contact.persona?.accent} size={28} />
          : bot ? <BotAvatar kind={contact.bot_kind} faction={contact.faction} /> : <IceAvatar kind={contact.ice_kind} />}
        {contact.name}{contact.self ? ' · вы' : ''}
      </Box>
      {!!contact.persona?.tagline && <Box className="netrun-contact-tagline">{contact.persona.tagline}</Box>}
      <Box color={THEME.muted} fontSize="11px">
        {contactKind(contact)} · {contact.state}
        {' · '}{contact.integrity}/{contact.max_integrity}
      </Box>
      {bot && !!contact.goal && <Box fontSize="11px">Задача: {contact.goal}</Box>}
      {blackIce && <BlackIceWarning />}
      {!!contact.threat && <Box mt={0.5} color={THEME.warn} fontSize="11px">{contact.threat}</Box>}
      {!contact.self && contact.kind === 'entity' && (
        <Box mt={0.5}>
          <Button compact icon="satellite-dish" content="Послать сигнал"
            disabled={pending || !contact.can_signal}
            onClick={() => act('entity_signal', { ref: contact.ref })} />
          <form onSubmit={(event) => { event.preventDefault(); send(); }}
            style={{ display: 'flex', gap: '4px', marginTop: '5px', minWidth: 0 }}>
            <input aria-label={`Сообщение для ${contact.name}`} placeholder="Личное сообщение…"
              value={message} maxLength={240} disabled={!canMessage}
              onChange={(event) => setMessage(event.target.value.slice(0, 240))}
              style={{ flex: '1 1 0', minWidth: 0, background: THEME.bg, color: THEME.text,
                border: `1px solid ${THEME.line}`, padding: '4px', fontFamily: 'monospace' }} />
            <Button compact icon="paper-plane" tooltip={`Отправить сообщение ${contact.name}`}
              disabled={!canMessage || !message.trim()} onClick={send} />
          </form>
        </Box>
      )}
    </Box>
  );
};
