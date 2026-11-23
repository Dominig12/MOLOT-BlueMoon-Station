import { useState } from 'react';

import { Box, Button, Dropdown, Input, NoticeBox, Stack } from '../components';
import { DeliveryStatus } from './NetdmDelivery';
import { DeviceEntry } from './NetdmDeviceState';
import {
  actionFields,
  actionLabel,
  argumentError,
  invocationLine,
  isReadAction,
  latestApiReply,
  serviceActions,
  ServiceField,
} from './NetdmServiceSchema';

type Props = {
  instance: string;
  type: string;
  entries: DeviceEntry[];
  onCommand: (line: string) => void;
  disabled?: boolean;
};

const fieldValue = (values: Record<string, string>, key: string) => values[key] ?? '';

/** One field from the service's real request schema; never creates implicit parameters. */
const ActionField = ({
  field, value, onChange,
}: { field: ServiceField; value: string; onChange: (value: string) => void }) => {
  const error = argumentError(field, value);
  const label = field.name.replace(/_/g, ' ');
  return (
    <div className="NetdmHome__formField">
      <div className="NetdmHome__formLabel">
        {label}{field.required ? ' *' : ''}
        <span>{field.type}{field.spec ? ` · ${field.spec}` : ''}</span>
      </div>
      {field.type === 'boolean' ? (
        <Stack>
          <Stack.Item>
            <Button selected={value === 'true'} content="Да" onClick={() => onChange('true')} />
            <Button selected={value === 'false'} content="Нет" onClick={() => onChange('false')} />
          </Stack.Item>
        </Stack>
      ) : field.type === 'enum' && field.choices.length > 0 ? (
        <Dropdown
          options={field.choices}
          selected={value || 'Выберите значение'}
          onSelected={onChange}
        />
      ) : (
        <Input
          fluid
          maxLength={Math.min(field.maxLength ?? 128, 256)}
          placeholder={field.type === 'integer' || field.type === 'number' ? 'Число' : 'Значение'}
          value={value}
          onInput={(_event: unknown, next: string) => onChange(next)}
        />
      )}
      {!!value && !!error && <Box color="bad">{error}</Box>}
    </div>
  );
};

const ActionResult = ({ entry, entries, onCommand }: {
  entry?: DeviceEntry;
  entries: DeviceEntry[];
  onCommand: (line: string) => void;
}) => {
  if (!entry) return null;
  const value = (field: string) => entry.records.flatMap(row => row)
    .find(item => item.name === field)?.value;
  const status = value('status') ?? entry.status;
  const operation = value('operation');
  const sent = entry.status === 'ok' && status === 'sent';
  const started = !!entry.pending;
  const failed = !started && !sent && status !== 'ok';
  if (entry.delivery) {
    const operation = entry.delivery.operation;
    const resultLine = /^[1-9][0-9]{0,18}$/.test(operation) ? `result ${operation}` : null;
    const reply = resultLine ? latestApiReply(entries, resultLine) : undefined;
    return (
      <div className="NetdmHome__actionResult" role="status">
        <DeliveryStatus delivery={entry.delivery} />
        {entry.delivery.state === 'delivered' && resultLine && (
          <Button icon="list-alt" disabled={!!reply?.pending} onClick={() => onCommand(resultLine)}>
            Показать ответ
          </Button>
        )}
        {reply && !reply.pending && (reply.status === 'ok' && reply.records.length > 0 ? (
          <dl className="NetdmDeliveryActivity__fields">
            {reply.records[0].map(field => (
              <div key={field.name}><dt>{field.name}</dt><dd>{field.value}</dd></div>
            ))}
          </dl>
        ) : <Box color="label">Содержимое ответа недоступно.</Box>)}
      </div>
    );
  }
  return (
    <div className="NetdmHome__actionResult" role="status">
      {started ? 'Запрос отправляется по сети…'
        : sent ? 'Сеть приняла запрос. Это ещё не подтверждение исполнения.'
          : failed ? `Запрос отклонён: ${status || 'нет ответа'}`
            : 'Ответ получен. Подробности доступны в журнале.'}
      {sent && operation && /^[1-9][0-9]{0,17}$/.test(operation) && (
        <Button icon="tasks" content="Проверить выполнение"
          onClick={() => onCommand(`jobs | where operation -eq "${operation}"`)} />
      )}
    </div>
  );
};

/**
 * Progressive, schema-backed control surface.
 * 1) Player requests command catalogue (no network side-effect from mounting this UI).
 * 2) Player chooses a command and receives its authoritative argument schema.
 * 3) Player enters validated values; dangerous actions require confirmation.
 * All traffic goes through the existing shell, never through a UI-specific shortcut.
 */
export const NetdmServiceActions = ({ instance, type, entries, onCommand, disabled = false }: Props) => {
  const [open, setOpen] = useState(false);
  const [selected, setSelected] = useState<string | null>(null);
  const [values, setValues] = useState<Record<string, string>>({});
  const catalogueLine = `api ${type}`;
  const catalogue = latestApiReply(entries, catalogueLine);
  const actions = serviceActions(catalogue, type).slice(0, 16);
  const chosen = actions.find(action => action.command === selected) ?? null;
  const schemaLine = chosen ? `api ${type} ${chosen.command}` : '';
  const schema = chosen ? latestApiReply(entries, schemaLine) : undefined;
  const fields = chosen && schema ? actionFields(schema, type, chosen.command) : [];
  const valid = chosen && schema?.status === 'ok' && !schema.pending &&
    fields.every(field => argumentError(field, fieldValue(values, field.name)) === null);
  const line = chosen && valid ? invocationLine(instance, chosen.command, fields, values) : null;
  const lastExecution = line ? latestApiReply(entries, line) : undefined;

  const toggle = () => {
    if (!open && !catalogue && !disabled) onCommand(catalogueLine);
    setOpen(!open);
  };
  const choose = (command: string) => {
    setSelected(command);
    setValues({});
    // Re-read metadata at explicit selection; no controls are generated from guesses.
    if (!disabled) onCommand(`api ${type} ${command}`);
  };

  return (
    <div className="NetdmHome__actionsSection">
      <Button icon={open ? 'chevron-up' : 'sliders-h'}
        content={open ? 'Скрыть действия' : 'Доступные действия'}
        onClick={toggle} />
      {open && (
        <div className="NetdmHome__actionsExplorer">
          <div className="NetdmHome__sectionLabel">КОМАНДЫ УСТРОЙСТВА</div>
          {disabled && !catalogue ? (
            <div className="NetdmHome__minor">
              Сервис недоступен или присутствие неактивно. Запрос команд не отправлялся.
            </div>
          ) : !catalogue || catalogue.pending ? (
            <div className="NetdmHome__minor">Запрашиваем список команд через сеть…</div>
          ) : catalogue.status !== 'ok' ? (
            <NoticeBox warning>
              Список действий пока недоступен.
              <Button icon="redo" content="Повторить" onClick={() => onCommand(catalogueLine)} />
            </NoticeBox>
          ) : actions.length === 0 ? (
            <div className="NetdmHome__minor">Для этого сервиса нет доступных команд в каталоге.</div>
          ) : (
            <>
              <Box mt={0.5}>
                <Button icon="sync" disabled={disabled} content="Обновить список"
                  onClick={() => onCommand(catalogueLine)} />
              </Box>
              <div className="NetdmHome__actionChoices">
                {actions.map(action => (
                  <Button key={action.command} content={actionLabel(action.command)}
                    selected={selected === action.command}
                    disabled={disabled}
                    onClick={() => choose(action.command)} />
                ))}
              </div>
              {!!chosen && (
                <div className="NetdmHome__actionForm">
                  <div className="NetdmHome__sectionLabel">
                    {actionLabel(chosen.command)} · {chosen.command}
                  </div>
                  {!schema || schema.pending ? (
                    <div className="NetdmHome__minor">Получаем параметры команды…</div>
                  ) : schema.status !== 'ok' ? (
                    <NoticeBox warning>Не удалось получить параметры. Команда не отправлена.</NoticeBox>
                  ) : (
                    <>
                      {fields.map(field => (
                        <ActionField key={field.name} field={field}
                          value={fieldValue(values, field.name)}
                          onChange={next => setValues(previous => ({
                            ...previous, [field.name]: next,
                          }))} />
                      ))}
                      {fields.length === 0 && (
                        <div className="NetdmHome__minor">Для этой команды не нужны параметры.</div>
                      )}
                      {isReadAction(chosen.command) ? (
                        <Button icon="search" content="Отправить запрос"
                          disabled={disabled || !line}
                          onClick={() => line && onCommand(line)} />
                      ) : (
                        <Button.Confirm icon="exclamation-triangle" color="average"
                          content="Отправить команду"
                          confirmContent="Подтвердить сетевую команду?"
                          disabled={disabled || !line}
                          onClick={() => line && onCommand(line)} />
                      )}
                      <div className="NetdmHome__minor">
                        Команда выполняется только после проверки прав, маршрута и состояния получателя.
                        Подтверждение отправки не означает применения.
                      </div>
                      <ActionResult entry={lastExecution} entries={entries} onCommand={onCommand} />
                    </>
                  )}
                </div>
              )}
            </>
          )}
        </div>
      )}
    </div>
  );
};
