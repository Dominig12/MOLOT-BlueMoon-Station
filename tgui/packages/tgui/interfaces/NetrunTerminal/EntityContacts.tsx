import { useState } from 'react';

import { Box, Button, Icon } from '../../components';
import { EntityAvatar } from './EntityAvatar';
import { EntityContact, THEME } from './types';
import { useNetrunBackend as useBackend } from './useNetrunBackend';

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
  const send = () => {
    const text = message.trim();
    if (!canMessage || !text) { return; }
    act('entity_message', { ref: contact.ref, text });
    setMessage('');
  };
  return (
    <Box p={1} mb={0.5} style={{ background: THEME.bg, border: `1px solid ${THEME.line}` }}>
      <Box bold>
        {contact.kind === 'entity' ? <EntityAvatar avatar={contact.persona?.avatar} accent={contact.persona?.accent} size={28} /> : <Icon name="shield-halved" mr={0.5} />}
        {contact.name}{contact.self ? ' · вы' : ''}
      </Box>
      {!!contact.persona?.tagline && <Box className="netrun-contact-tagline">{contact.persona.tagline}</Box>}
      <Box color={THEME.muted} fontSize="11px">
        {contact.kind === 'ice' ? 'ICE' : 'Сущность'} · {contact.state}
        {' · '}{contact.integrity}/{contact.max_integrity}
      </Box>
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
