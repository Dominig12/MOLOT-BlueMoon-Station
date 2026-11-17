import { useState } from 'react';

import { Box, Button, Dropdown, Input, NoticeBox, Stack } from '../components';
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

const ActionResult = ({ entry, onCommand }: {
  entry?: DeviceEntry;
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
export const NetdmServiceActions = ({ instance, type, entries, onCommand }: Props) => {
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
    if (!open && !catalogue) onCommand(catalogueLine);
    setOpen(!open);
  };
  const choose = (command: string) => {
    setSelected(command);
    setValues({});
    // Re-read metadata at explicit selection; no controls are generated from guesses.
    onCommand(`api ${type} ${command}`);
  };

  return (
    <div className="NetdmHome__actionsSection">
      <Button icon={open ? 'chevron-up' : 'sliders-h'}
        content={open ? 'Скрыть действия' : 'Доступные действия'}
        onClick={toggle} />
      {open && (
        <div className="NetdmHome__actionsExplorer">
          <div className="NetdmHome__sectionLabel">КОМАНДЫ УСТРОЙСТВА</div>
          {!catalogue || catalogue.pending ? (
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
              <div className="NetdmHome__actionChoices">
                {actions.map(action => (
                  <Button key={action.command} content={actionLabel(action.command)}
                    selected={selected === action.command}
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
                          disabled={!line}
                          onClick={() => line && onCommand(line)} />
                      ) : (
                        <Button.Confirm icon="exclamation-triangle" color="average"
                          content="Отправить команду"
                          confirmContent="Подтвердить сетевую команду?"
                          disabled={!line}
                          onClick={() => line && onCommand(line)} />
                      )}
                      <div className="NetdmHome__minor">
                        Команда выполняется только после проверки прав, маршрута и состояния получателя.
                        Подтверждение отправки не означает применения.
                      </div>
                      <ActionResult entry={lastExecution} onCommand={onCommand} />
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
