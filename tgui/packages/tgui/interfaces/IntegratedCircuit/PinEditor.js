import { useEffect, useState } from 'react';

import { useBackend } from '../../backend';
import {
  Box,
  Button,
  Dropdown,
  Input,
  Modal,
  Section,
  Stack,
  TextArea,
} from '../../components';
import { byondListToArray } from './byondPayload';

const LIST_KINDS = [
  'string',
  'number',
  'boolean',
  'null',
];

const KIND_LABEL = {
  string: 'текст',
  number: 'число',
  boolean: 'bool',
  null: 'null',
  ref: 'ref',
  list: 'list',
  text: 'текст',
};

/**
 * Нативный редактор значения пина: список (добавить/убрать/передвинуть/очистить,
 * поправить ячейку) или длинный текст (для string/any). Заменяет старый браузерный
 * popup list_pin.dm — удобнее и не зависит от отдельного окна браузера.
 */
export const PinEditor = (props) => {
  const { act, data } = useBackend();
  const editor = data.pin_editor;

  if (!editor) {
    return null;
  }

  const close = () => act('ie_pin_editor_close');

  return (
    <Modal className="PinEditor__modal">
      <Section
        title={`Редактор: ${editor.name}`}
        buttons={(
          <Button
            icon="times"
            color="transparent"
            tooltip="Закрыть"
            onClick={close}
          />
        )}>
        <Box mb={0.5} className="PinEditor__subtitle">
          Тип: <b>{editor.type}</b>
          {' '}
          {editor.is_output ? '(выход)' : '(вход)'}
        </Box>
        {editor.kind === 'list'
          ? (
            <>
              <ListEditor editor={editor} act={act} />
              <AddRowForm act={act} />
            </>
          )
          : (
            <ValueEditor editor={editor} act={act} />
          )}
      </Section>
    </Modal>
  );
};

const ListEditor = (props) => {
  const { editor, act } = props;
  const rows = byondListToArray(editor.rows);

  if (!rows.length) {
    return (
      <Box className="PinEditor__empty" py={1}>
        Список пуст. Добавьте элемент ниже.
      </Box>
    );
  }

  return (
    <Box className="PinEditor__list">
      <Box
        className="PinEditor__listHeader"
        font-size="0.78rem"
        opacity={0.6}
        mb={0.25}>
        Элементов: <b>{editor.length}</b>
      </Box>
      <Stack vertical>
        {rows.map((row) => (
          <ListRow
            key={`${row.index}-${row.display}`}
            row={row}
            act={act}
          />
        ))}
      </Stack>
      <Box mt={0.5}>
        <Button
          icon="trash"
          color="bad"
          onClick={() => act('ie_list_edit', { edit_action: 'clear' })}>
          Очистить список
        </Button>
      </Box>
    </Box>
  );
};

const ListRow = (props) => {
  const { row, act } = props;
  const editable = row.kind === 'string' || row.kind === 'number'
    || row.kind === 'boolean' || row.kind === 'null' || row.kind === 'text';

  return (
    <Stack className="PinEditor__row" align="center">
      <Stack.Item width="2.4rem">
        <Box textAlign="right" opacity={0.55} className="PinEditor__idx">
          #{row.index}
        </Box>
      </Stack.Item>
      <Stack.Item width="3.6rem">
        <Box className="PinEditor__kind" textAlign="center">
          {KIND_LABEL[row.kind] || row.kind}
        </Box>
      </Stack.Item>
      <Stack.Item grow={1}>
        {editable
          ? (
            <EditCell row={row} act={act} />
          )
          : (
            <Box className="PinEditor__display">
              {row.display}
            </Box>
          )}
      </Stack.Item>
      <Stack.Item>
        <Button
          icon="arrow-up"
          compact
          color="transparent"
          tooltip="Выше"
          onClick={() => act('ie_list_edit', {
            edit_action: 'move',
            index: row.index,
            text: '-1',
          })}
        />
      </Stack.Item>
      <Stack.Item>
        <Button
          icon="arrow-down"
          compact
          color="transparent"
          tooltip="Ниже"
          onClick={() => act('ie_list_edit', {
            edit_action: 'move',
            index: row.index,
            text: '1',
          })}
        />
      </Stack.Item>
      <Stack.Item>
        <Button
          icon="times"
          compact
          color="transparent"
          tooltip="Удалить"
          onClick={() => act('ie_list_edit', {
            edit_action: 'remove',
            index: row.index,
          })}
        />
      </Stack.Item>
    </Stack>
  );
};

const EditCell = (props) => {
  const { row, act } = props;
  const initial = row.kind === 'null' ? '' : String(row.display);
  const commit = (value) => {
    act('ie_list_edit', {
      edit_action: 'set',
      index: row.index,
      kind: row.kind,
      text: value,
    });
  };
  return (
    <Input
      fluid
      placeholder={row.kind}
      defaultValue={initial}
      onEnter={(e, value) => commit(value)}
      onBlur={(e) => {
        const val = e.target.value;
        if (val !== initial) {
          commit(val);
        }
      }}
    />
  );
};

const AddRowForm = (props) => {
  const { act } = props;
  const [addKind, setAddKind] = useState('string');
  const [localText, setLocalText] = useState('');

  const add = () => {
    act('ie_list_edit', {
      edit_action: 'add',
      kind: addKind,
      text: localText,
    });
    setLocalText('');
  };

  const kindOptions = LIST_KINDS.map((k) => KIND_LABEL[k] || k);

  return (
    <Section title="Добавить элемент" mt={0.75}>
      <Stack align="center">
        <Stack.Item>
          <Dropdown
            width="7rem"
            displayText={KIND_LABEL[addKind] || addKind}
            options={kindOptions}
            onSelected={(label) => {
              const k = LIST_KINDS.find(
                (kk) => (KIND_LABEL[kk] || kk) === label,
              ) || 'string';
              setAddKind(k);
              setLocalText('');
            }}
          />
        </Stack.Item>
        <Stack.Item grow={1}>
          <Input
            fluid
            placeholder={addKind === 'boolean' ? 'true / false' : 'значение'}
            value={localText}
            onChange={(e, val) => setLocalText(val)}
            onEnter={() => add()}
          />
        </Stack.Item>
        <Stack.Item>
          <Button icon="plus" color="good" onClick={add}>
            Добавить
          </Button>
        </Stack.Item>
      </Stack>
    </Section>
  );
};

const ValueEditor = (props) => {
  const { editor, act } = props;
  const init = editor.value === null || editor.value === undefined
    ? ''
    : String(editor.value);
  const [draft, setDraft] = useState(init);

  // Синхронизация черновика после собственной записи/очистки (сервер вернул новое значение).
  useEffect(() => {
    setDraft(init);
  }, [init]);

  const commit = () => {
    act('ie_value_edit', { text: draft });
  };

  return (
    <Box>
      <TextArea
        fluid
        height="16rem"
        placeholder="значение…"
        value={init}
        onInput={(e, val) => setDraft(val)}
      />
      <Stack mt={0.5} justify="flex-end">
        <Stack.Item>
          <Button icon="save" color="good" onClick={commit}>
            Записать
          </Button>
        </Stack.Item>
        <Stack.Item>
          <Button
            icon="eraser"
            onClick={() => act('ie_value_edit', { text: null })}>
            Очистить (null)
          </Button>
        </Stack.Item>
      </Stack>
    </Box>
  );
};