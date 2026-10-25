import { memo } from 'react';

import { Box, Button } from '../../components';
import { IncomingAttacks } from './CombatPanel';
import { OPERATION_PHASES, operationActive } from './OperationsPanel';
import { NetrunData, normalizeOperations, THEME } from './types';
import { useNetrunBackend as useBackend, useNetrunFeedback } from './useNetrunBackend';

/** A reserved row keeps urgent feedback visible without moving tools or taking focus. */
const SessionStatusView = (props: { onCombat: () => void; onBreach: () => void; onOperations?: () => void }) => {
  const { act, data } = useBackend<NetrunData>(['combat', 'entity', 'locked', 'breach', 'operations']);
  const feedback = useNetrunFeedback();
  const incoming = !!data.combat?.incoming?.length;
  const travel = data.entity?.travel;
  const operations = normalizeOperations(data.operations);
  const latestOperation = operations[operations.length - 1];
  const operation = feedback
    ? operations.find((entry) => entry.nonce === feedback.nonce)
    : latestOperation;
  const operationState = operation ? OPERATION_PHASES[operation.phase] : null;
  return (
    <div data-net-layout="status" style={{ display: 'flex', alignItems: 'center', gap: '6px',
      flex: '0 0 32px', height: '32px', minWidth: 0, overflow: 'hidden' }}>
      <div style={{ flex: '1 1 auto', minWidth: 0, height: '100%', display: 'flex', alignItems: 'center' }}>
        {incoming ? <IncomingAttacks compact onCombat={props.onCombat} /> : (
          <>
            <Box role="status" aria-live="polite" data-net-feedback={feedback?.phase}
              color={data.locked > 0 ? THEME.bad : operationState?.color || (feedback?.phase === 'delayed' ? THEME.warn : THEME.muted)} fontSize="11px"
              style={{ flex: '1 1 auto', minWidth: 0, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
              {data.locked > 0 ? `Сеанс заблокирован · осталось ${data.locked} с`
                : operation && (feedback || operationActive(operation)) ? `${operationState?.label}: ${operation.label}${operation.reason ? ` · ${operation.reason}` : ''}`
                  : feedback ? `${feedback.phase === 'received' ? 'Сервер ответил' : feedback.phase === 'delayed' ? 'Ответ задерживается' : 'Отправлен запрос'}: ${feedback.label}`
                  : data.breach ? `${data.breach.target} · взлом продолжается · ${data.breach.time_left} с`
                  : travel ? `Автопроход к ${travel.target} · осталось переходов: ${travel.remaining}`
                    : operation ? `${operationState?.label}: ${operation.label}${operation.reason ? ` · ${operation.reason}` : ''}`
                    : 'Выберите узел на карте и откройте управление. В терминале доступна команда help.'}
            </Box>
            {!!data.breach && <Button compact icon="key" content="К взлому" onClick={props.onBreach} />}
          </>
        )}
      </div>
      {!!travel && <Button compact icon="stop" content={incoming ? 'Стоп' : 'Остановить маршрут'}
        aria-label="Остановить автопроход" tooltip={`Остановить автопроход к ${travel.target}`}
        onClick={() => act('travel_cancel')} />}
      {!!props.onOperations && <Button compact role="button" icon="list-check" content={`Операции${operations.some(operationActive) ? ` (${operations.filter(operationActive).length})` : ''}`}
        onClick={props.onOperations} />}
    </div>
  );
};

export const SessionStatus = memo(SessionStatusView);
