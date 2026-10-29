import { useState } from 'react';

import { Box, Button } from '../../components';
import { EntityAvatar } from './EntityAvatar';
import { NETRUN_THEMES } from './themes';
import { AgentBuilder, NetrunData, THEME } from './types';
import { useNetrunBackend as useBackend } from './useNetrunBackend';

/** A private template produces an independent executable package, ready to launch from Files. */
export const AgentBuilderPanel = ({ builder }: { builder: AgentBuilder }) => {
  const { act, data } = useBackend<NetrunData>(['storage', 'shard']);
  const [open, setOpen] = useState(false);
  const [name, setName] = useState(builder.name);
  const [avatar, setAvatar] = useState(builder.avatars[0]?.id || 'cipher');
  const [accent, setAccent] = useState(builder.accents[0]?.id || 'cyan');
  const [tagline, setTagline] = useState('');
  const [theme, setTheme] = useState(builder.themes.includes('ion') ? 'ion' : builder.themes[0]);
  const [order, setOrder] = useState(builder.orders[0]?.id || 'guard');
  const [includeDefaults, setIncludeDefaults] = useState(true);
  const [selected, setSelected] = useState<string[]>([]);
  const [toShard, setToShard] = useState(false);
  // Removed media/programs disappear from the request as soon as a new payload arrives.
  const programs = builder.programs.filter((program) => selected.includes(program.uid));
  const used = (includeDefaults ? builder.defaults.reduce((sum, program) => sum + program.size, 0) : 0)
    + programs.reduce((sum, program) => sum + program.size, 0);
  const size = builder.base_size + used;
  const onShard = toShard && !!data.shard;
  const destination = onShard ? data.shard : data.storage;
  const remaining = destination ? destination.capacity - destination.used : 0;
  const overfull = used > builder.capacity || size > remaining;
  const valid = !!name.trim() && !overfull;
  const create = () => {
    if (!valid) { return; }
    act('agent_create', { uid: builder.template_uid, name: name.trim(), avatar, accent, tagline, theme, order,
      include_defaults: includeDefaults, program_uids: programs.map((program) => program.uid), to_shard: onShard });
  };
  return (<Box mt={1} data-net-agent-builder={builder.profile}>
    <Button compact icon="robot" content="Собрать своего агента" selected={open} onClick={() => setOpen(!open)} />
    {open && <form className="netrun-agent-form" aria-label="Конструктор агента" onSubmit={(event) => { event.preventDefault(); create(); }}>
      <Box bold>{builder.name}</Box>
      <Box color={THEME.muted} fontSize="11px">{builder.description}</Box>
      <label className="netrun-field">Имя агента<input value={name} maxLength={42} onChange={(event) => setName(event.target.value)} /></label>
      <div className="netrun-agent-form__row">
        <EntityAvatar avatar={avatar} accent={accent} size={38} />
        <label className="netrun-field">Аватар<select value={avatar} onChange={(event) => setAvatar(event.target.value)}>
          {builder.avatars.map((choice) => <option key={choice.id} value={choice.id}>{choice.name}</option>)}
                                              </select>
        </label>
        <label className="netrun-field">Цвет<select value={accent} onChange={(event) => setAccent(event.target.value)}>
          {builder.accents.map((choice) => <option key={choice.id} value={choice.id}>{choice.name}</option>)}
                                            </select>
        </label>
      </div>
      <label className="netrun-field">Подпись<input value={tagline} maxLength={80} onChange={(event) => setTagline(event.target.value)} /></label>
      <label className="netrun-field">Оформление<select value={theme} onChange={(event) => setTheme(event.target.value)}>
        {builder.themes.map((id) => <option key={id} value={id}>{NETRUN_THEMES[id]?.name || id}</option>)}
                                                </select>
      </label>
      <label className="netrun-field">Начальная задача<select value={order} onChange={(event) => setOrder(event.target.value)}>
        {builder.orders.map((choice) => <option key={choice.id} value={choice.id}>{choice.name}</option>)}
                                                      </select>
      </label>
      <fieldset style={{ border: `1px solid ${THEME.line}`, margin: 0, padding: '6px' }}>
        <legend>Программы · память {used}/{builder.capacity}</legend>
        <label style={{ display: 'block' }}><input type="checkbox" checked={includeDefaults} onChange={(event) => setIncludeDefaults(event.target.checked)} /> Штатный набор</label>
        {!!includeDefaults && <Box ml={2} color={THEME.muted} fontSize="11px">
          {builder.defaults.map((program) => `${program.name} (${program.size})`).join(' · ') || 'Нет штатных программ'}
                              </Box>}
        {builder.programs.map((program) => (<label key={program.uid} style={{ display: 'block' }}>
          <input type="checkbox" checked={selected.includes(program.uid)}
            disabled={!selected.includes(program.uid) && programs.length >= (builder.max_programs ?? 8)}
            onChange={(event) => setSelected(event.target.checked ? [...selected, program.uid] : selected.filter((uid) => uid !== program.uid))} />
          {' '}{program.name} · {program.size}
                                            </label>))}
        {!builder.programs.length && <Box color={THEME.muted} fontSize="11px">Дополнительные программы можно выбрать из памяти или шарда.</Box>}
      </fieldset>
      <label className="netrun-field">Сохранить агента<select value={onShard ? 'shard' : 'local'} onChange={(event) => setToShard(event.target.value === 'shard')}>
        <option value="local">Локальная память</option>
        {!!data.shard && <option value="shard">{data.shard.name}</option>}
                                                      </select>
      </label>
      <Box color={overfull ? THEME.warn : THEME.muted} fontSize="11px">
        {used > builder.capacity ? 'Программы не помещаются в память агента.'
          : size > remaining ? `Недостаточно места: нужно ${size}, свободно ${remaining}.`
            : `Файл займёт ${size}; свободно ${remaining}.`}
      </Box>
      <Box color={THEME.muted} fontSize="11px">После создания выберите новый файл и запустите агента. Шаблон и выбранные программы сохраняются.</Box>
      <Button compact icon="check" content="Создать агента" disabled={!valid} onClick={create} />
             </form>}
          </Box>);
};
