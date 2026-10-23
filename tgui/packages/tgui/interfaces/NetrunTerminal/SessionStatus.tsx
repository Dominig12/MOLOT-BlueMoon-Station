import { Box, Button } from '../../components';
import { IncomingAttacks } from './CombatPanel';
import { NetrunData, THEME } from './types';
import { useNetrunBackend as useBackend, useNetrunFeedback } from './useNetrunBackend';

/** A reserved row keeps urgent feedback visible without moving tools or taking focus. */
export const SessionStatus = (props: { onCombat: () => void; onBreach: () => void }) => {
  const { act, data } = useBackend<NetrunData>();
  const feedback = useNetrunFeedback();
  const incoming = !!data.combat?.incoming?.length;
  const travel = data.entity?.travel;
  return (
    <div data-net-layout="status" style={{ display: 'flex', alignItems: 'center', gap: '6px',
      flex: '0 0 32px', height: '32px', minWidth: 0, overflow: 'hidden' }}>
      <div style={{ flex: '1 1 auto', minWidth: 0, height: '100%', display: 'flex', alignItems: 'center' }}>
        {incoming ? <IncomingAttacks compact onCombat={props.onCombat} /> : (
          <>
            <Box role="status" aria-live="polite" data-net-feedback={feedback?.phase}
              color={data.locked > 0 ? THEME.bad : feedback?.phase === 'delayed' ? THEME.warn : THEME.muted} fontSize="11px"
              style={{ flex: '1 1 auto', minWidth: 0, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
              {data.locked > 0 ? `Сеанс заблокирован · осталось ${data.locked} с`
                : feedback ? `${feedback.phase === 'received' ? 'Сервер ответил' : feedback.phase === 'delayed' ? 'Ответ задерживается' : 'Отправлен запрос'}: ${feedback.label}`
                  : data.breach ? `${data.breach.target} · взлом продолжается · ${data.breach.time_left} с`
                  : travel ? `Автопроход к ${travel.target} · осталось переходов: ${travel.remaining}`
                    : 'Выберите узел на карте и откройте управление. В терминале доступна команда help.'}
            </Box>
            {!!data.breach && <Button compact icon="key" content="К взлому" onClick={props.onBreach} />}
          </>
        )}
      </div>
      {!!travel && <Button compact icon="stop" content={incoming ? 'Стоп' : 'Остановить маршрут'}
        aria-label="Остановить автопроход" tooltip={`Остановить автопроход к ${travel.target}`}
        onClick={() => act('travel_cancel')} />}
    </div>
  );
};
