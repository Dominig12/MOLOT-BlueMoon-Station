import { render } from '@testing-library/react';

import { BotAvatar, EntityContacts, factionLabel } from './EntityContacts';
import type { EntityContact } from './types';

jest.mock('./useNetrunBackend', () => ({ useNetrunBackend: () => ({ act: jest.fn() }) }));

test('contact avatars resolve visitor roles and use sanitized faction metadata', () => {
  const panel = render(<BotAvatar kind="redshift_hacker" faction="redshift" factionColor="#123456" />);
  const avatar = panel.getByRole('img', { name: 'Бот: Диверсант Красного смещения' });
  expect(avatar.getAttribute('data-bot-glyph')).toBe('cipher');
  expect(avatar.style.color).toBe('rgb(18, 52, 86)');
  expect(avatar.querySelectorAll('svg path')).toHaveLength(2);
  panel.rerender(<BotAvatar kind="unknown" faction="owner:4" factionColor="var(--untrusted)" />);
  expect(panel.getByRole('img').style.color).toBe('rgb(119, 217, 173)');
  expect(panel.getByRole('img').getAttribute('data-bot-glyph')).toBe('robot');
  expect(factionLabel('bot', 'archivists')).toBe('Вольный архив');
  expect(factionLabel('fortress', 'owner:4')).toBe('частная');
});

test('contact card, faction label and role icon agree on the authoritative faction colour', () => {
  const contact: EntityContact = { ref: 'r', name: 'A-7', kind: 'bot', bot_kind: 'archive_collector', faction: 'archivists',
    faction_name: 'Вольный архив', faction_color: '#d5c77d', integrity: 70, max_integrity: 90, state: 'сбор',
    self: false, can_signal: false, can_message: false };
  const panel = render(<EntityContacts address="ENG:1" contacts={[contact]} pending={false} localEntity={false} />);
  expect(panel.getByRole('img').getAttribute('data-bot-glyph')).toBe('archive');
  expect(panel.getByRole('img').style.color).toBe('rgb(213, 199, 125)');
  expect(panel.getByText('Вольный архив').style.color).toBe('rgb(213, 199, 125)');
  expect(panel.container.querySelector<HTMLElement>('[data-net-contact]').style.borderColor).toBe('rgb(213, 199, 125)');
  expect(panel.getByText(/Собиратель Вольного архива/)).toBeTruthy();
});
