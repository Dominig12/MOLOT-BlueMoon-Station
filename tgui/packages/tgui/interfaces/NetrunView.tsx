import { useState } from 'react';

import { useBackend } from '../backend';
import { Box, Button, Icon, NoticeBox, ProgressBar, Section, Stack, Table, TextArea } from '../components';
import { Window } from '../layouts';
import { NetrunMap } from './NetrunView/Map';
import {
  ActionView,
  AgentView,
  Data,
  findHost,
  formatAge,
  formatCooldown,
  BackupView,
  HostView,
  LifeView,
  OperationView,
  PresenceView,
  PresetView,
  ProgramView,
  summarise,
  TabKey,
  TABS,
} from './NetrunView/model';

type Act = (action: string, params?: Record<string, unknown>) => void;

const levelText: Record<string, string> = {
  unknown: 'неизвестно',
  anomaly: 'аномалия',
  observed: 'наблюдается',
  identified: 'опознан',
};

const statusText: Record<string, string> = {
  committed: 'выполнено',
  accepted: 'отправлено',
  cancelled: 'отменено',
  rejected: 'отклонено',
  duplicate: 'повтор',
  forbidden: 'нет прав',
  cooldown: 'перезарядка',
  unknown_outcome: 'исход неизвестен',
};

const Sidebar = ({ tab, onTab }: { tab: TabKey; onTab: (key: TabKey) => void }) => (
  <Stack vertical width="132px" fill>
    {TABS.map(entry => (
      <Stack.Item key={entry.key}>
        <Button
          fluid
          selected={tab === entry.key}
          onClick={() => onTab(entry.key)}
          icon={entry.icon}
          content={entry.label}
        />
      </Stack.Item>
    ))}
  </Stack>
);

/**
 * The digital core of the operator: what it is, how damaged it is, which generation controls it, and the three
 * operations that matter — make a copy, move the core, restore it. Everything here is a request to the Host.
 */
const LifeTab = ({
  core,
  backups,
  presence,
  selected,
  onLife,
  onRestore,
}: {
  core?: LifeView;
  backups: BackupView[];
  onRestore: (backup: number) => void;
  presence?: PresenceView;
  selected: number | null;
  onLife: (action: string, target?: number) => void;
}) => {
  if (!core) {
    return (
      <Section>
        <NoticeBox info>
          У вас нет цифрового ядра. Выберите хост и создайте его: ядро живёт только там, где хватает вычислений
          и памяти.
        </NoticeBox>
        <Button
          mt={1}
          icon="plus"
          content="Создать ядро на выбранном хосте"
          disabled={!selected}
          onClick={() => onLife('create', selected ?? undefined)}
        />
      </Section>
    );
  }
  const integrity = Math.max(0, Math.min(100, core.integrity));
  return (
    <Section title="Цифровое ядро">
      <Table>
        <Table.Row>
          <Table.Cell color="label">Состояние</Table.Cell>
          <Table.Cell>{core.state}</Table.Cell>
        </Table.Row>
        <Table.Row>
          <Table.Cell color="label">Целостность</Table.Cell>
          <Table.Cell>
            <ProgressBar value={integrity} minValue={0} maxValue={100} ranges={{ bad: [0, 33], average: [33, 66], good: [66, 100] }} />
          </Table.Cell>
        </Table.Row>
        <Table.Row>
          <Table.Cell color="label">Поколение управления</Table.Cell>
          <Table.Cell>{core.control}</Table.Cell>
        </Table.Row>
        <Table.Row>
          <Table.Cell color="label">Хост</Table.Cell>
          <Table.Cell>{core.host}</Table.Cell>
        </Table.Row>
        <Table.Row>
          <Table.Cell color="label">Присутствие</Table.Cell>
          <Table.Cell>
            {!presence
              ? 'не активно'
              : presence.state === 'traveling'
                ? `в пути (${presence.hops})`
                : `на хосте ${presence.host}`}
          </Table.Cell>
        </Table.Row>
      </Table>
      {backups.length > 0 && (
        <Section title="Копии" mt={1}>
          <Table>
            <Table.Row header>
              <Table.Cell>#</Table.Cell>
              <Table.Cell>Целостность</Table.Cell>
              <Table.Cell>Поколение</Table.Cell>
              <Table.Cell />
            </Table.Row>
            {backups.map(backup => (
              <Table.Row key={backup.id}>
                <Table.Cell>{backup.id}</Table.Cell>
                <Table.Cell>{backup.integrity}</Table.Cell>
                <Table.Cell>{backup.control}</Table.Cell>
                <Table.Cell>
                  <Button
                    compact
                    icon="undo"
                    content="Восстановить"
                    onClick={() => onRestore(backup.id)}
                  />
                </Table.Cell>
              </Table.Row>
            ))}
          </Table>
        </Section>
      )}
      <Stack mt={1}>
        <Stack.Item>
          <Button
            icon="copy"
            content="Копия на выбранном хосте"
            disabled={!selected}
            onClick={() => onLife('backup', selected ?? undefined)}
          />
        </Stack.Item>
        <Stack.Item>
          <Button
            icon="share"
            content="Перенести ядро"
            disabled={!selected || core.migrating}
            onClick={() => onLife('migrate', selected ?? undefined)}
          />
        </Stack.Item>
      </Stack>
    </Section>
  );
};

/**
 * The observer's strains: a virus that copies itself over existing links, or ICE that just defends. Every row is
 * what the Host reports, and every button is a request it may refuse.
 */
const AgentsTab = ({
  agents,
  selected,
  onAgent,
}: {
  agents: AgentView[];
  selected: number | null;
  onAgent: (action: string, extra?: Record<string, unknown>) => void;
}) => (
  <Section
    title="Штаммы"
    buttons={
      <>
        <Button
          icon="bug"
          content="Вирус"
          disabled={!selected}
          onClick={() => onAgent('deploy', { target: selected, kind: 'virus' })}
        />
        <Button
          ml={1}
          icon="shield"
          content="ICE"
          disabled={!selected}
          onClick={() => onAgent('deploy', { target: selected, kind: 'ice' })}
        />
        <Button
          ml={1}
          icon="broom"
          content="Очистить хост"
          disabled={!selected}
          onClick={() => onAgent('purge', { target: selected })}
        />
      </>
    }
  >
    {agents.length === 0 ? (
      <NoticeBox info>
        Ваших штаммов в сети нет. Вирус копируется по существующим связям, пока хватает бюджета и хост платит;
        ICE только защищает хост и никуда не идёт.
      </NoticeBox>
    ) : (
      <Table>
        <Table.Row header>
          <Table.Cell>Штамм</Table.Cell>
          <Table.Cell>Вид</Table.Cell>
          <Table.Cell>Хост</Table.Cell>
          <Table.Cell>Поколение</Table.Cell>
          <Table.Cell>Целостность</Table.Cell>
          <Table.Cell>Копий</Table.Cell>
          <Table.Cell />
        </Table.Row>
        {agents.map(agent => (
          <Table.Row key={agent.id}>
            <Table.Cell>{agent.strain}</Table.Cell>
            <Table.Cell>{agent.kind === 'ice' ? 'ICE' : 'вирус'}</Table.Cell>
            <Table.Cell>{agent.host}</Table.Cell>
            <Table.Cell>{agent.generation}</Table.Cell>
            <Table.Cell>{agent.integrity}</Table.Cell>
            <Table.Cell>{agent.spreads}</Table.Cell>
            <Table.Cell>
              <Button compact icon="trash" content="Снять" onClick={() => onAgent('clean', { agent: agent.id })} />
            </Table.Cell>
          </Table.Row>
        ))}
      </Table>
    )}
  </Section>
);

const HostContext = ({
  host,
  presence,
  onExecute,
  onTravel,
  onAbort,
}: {
  host: HostView;
  presence?: PresenceView;
  onExecute: (action: string) => void;
  onTravel: () => void;
  onAbort: () => void;
}) => (
  <Section title="Выбранный хост" width="240px">
    <Box bold>{host.name || host.hostClass}</Box>
    <Box color="label" fontSize={11}>
      ID {host.host} · {host.hostClass}
    </Box>
    <Table mt={1}>
      <Table.Row>
        <Table.Cell color="label">Знание</Table.Cell>
        <Table.Cell>{levelText[host.level] ?? host.level}</Table.Cell>
      </Table.Row>
      <Table.Row>
        <Table.Cell color="label">Данные</Table.Cell>
        <Table.Cell>{host.stale ? `устарели (${formatAge(host.ageMs)})` : `свежие (${formatAge(host.ageMs)})`}</Table.Cell>
      </Table.Row>
      <Table.Row>
        <Table.Cell color="label">Питание</Table.Cell>
        <Table.Cell>{host.available ? 'в норме' : 'нет питания'}</Table.Cell>
      </Table.Row>
      <Table.Row>
        <Table.Cell color="label">Буфер</Table.Cell>
        <Table.Cell>{host.bufferCu.toFixed(1)} CU</Table.Cell>
      </Table.Row>
      <Table.Row>
        <Table.Cell color="label">Эффекты</Table.Cell>
        <Table.Cell>{host.effects}</Table.Cell>
      </Table.Row>
    </Table>
    <Button
      mt={1}
      fluid
      icon="terminal"
      content="Осмотреть"
      onClick={() => onExecute('net.inspect')}
    />
    {presence?.state === 'traveling' ? (
      <Button mt={1} fluid icon="stop" color="bad" content="Прервать переход" onClick={onAbort} />
    ) : (
      <Button
        mt={1}
        fluid
        icon="walking"
        content={presence ? 'Идти сюда' : 'Войти'}
        disabled={presence?.host === host.host && presence?.state === 'idle'}
        onClick={onTravel}
      />
    )}
    <Box mt={1} color="label" fontSize={11}>
      {!presence
        ? 'Присутствие не активно'
        : presence.state === 'traveling'
          ? `В пути: ${presence.hops} переходов`
          : `Стою на хосте ${presence.host}`}
    </Box>
  </Section>
);

/** The host's own alert level (§9.3). Older projections do not send it, so it stays optional. */
const alertText: Record<string, string> = {
  Normal: 'обычно',
  Suspicious: 'насторожен',
  Alert: 'тревога',
  Hostile: 'враждебно',
  Lockdown: 'блокировка',
};

const alertColor = (alert?: string) => {
  if (!alert || alert === 'Normal') {
    return 'label';
  }
  if (alert === 'Lockdown' || alert === 'Hostile') {
    return 'bad';
  }
  return 'average';
};

const HostsTab = ({
  hosts,
  selected,
  onSelect,
}: {
  hosts: HostView[];
  selected: number | null;
  onSelect: (host: number) => void;
}) => (
  <Table>
    <Table.Row header>
      <Table.Cell>Хост</Table.Cell>
      <Table.Cell>Класс</Table.Cell>
      <Table.Cell>Знание</Table.Cell>
      <Table.Cell>Данные</Table.Cell>
      <Table.Cell>Буфер</Table.Cell>
      <Table.Cell>Тревога</Table.Cell>
    </Table.Row>
    {hosts.map(host => (
      <Table.Row key={host.host} className="candystripe">
        <Table.Cell>
          <Button fluid selected={selected === host.host} onClick={() => onSelect(host.host)}>
            {host.name || `${host.hostClass} #${host.host}`}
          </Button>
        </Table.Cell>
        <Table.Cell>{host.hostClass}</Table.Cell>
        <Table.Cell>{levelText[host.level] ?? host.level}</Table.Cell>
        <Table.Cell color={host.stale ? 'average' : 'good'}>{formatAge(host.ageMs)}</Table.Cell>
        <Table.Cell>{host.bufferCu.toFixed(1)} CU</Table.Cell>
        <Table.Cell color={alertColor(host.alert)}>
          {alertText[host.alert ?? 'Normal'] ?? host.alert}
        </Table.Cell>
      </Table.Row>
    ))}
    {hosts.length === 0 && (
      <Table.Row>
        <Table.Cell colSpan={6} color="label">
          Наблюдаемых хостов нет.
        </Table.Cell>
      </Table.Row>
    )}
  </Table>
);

const programStateText: Record<string, string> = {
  running: 'выполняется',
  waiting: 'ожидание',
  waitingforoperation: 'ждёт ответа',
  completed: 'завершена',
  faulted: 'остановлена',
  cancelled: 'отменена',
};

/**
 * The placeholder text of a fresh editor. It is a real program: pressing the button compiles and starts it,
 * and the server checks every action it invokes against the operator's rights.
 */
const DEFAULT_SOURCE = `program "Probe"
invoke net.inspect self
stop`;

const ProgramEditor = ({
  text,
  onChange,
  onRun,
}: {
  text: string;
  onChange: (text: string) => void;
  onRun: (text: string) => void;
}) => {
  return (
    <Section
      title="Редактор"
      buttons={
        <Button icon="play" content="Запустить" disabled={!text.trim()} onClick={() => onRun(text)} />
      }
    >
      <TextArea
        fluid
        height="120px"
        value={text}
        onInput={(_event, value) => onChange(value)}
        placeholder="program &quot;Probe&quot;"
      />
      <Box mt={1} color="label" fontSize={11}>
        Текст — это данные: права, стоимость и перезарядка проверяются на сервере при каждом действии.
      </Box>
    </Section>
  );
};

const PresetLibrary = ({ presets, onChoose }: { presets: PresetView[]; onChoose: (text: string) => void }) => {
  const [chosen, setChosen] = useState<string | null>(null);
  const current = presets.find(preset => preset.name === chosen) ?? null;
  return (
    <Section title="Библиотека программ">
      <Stack wrap>
        {presets.map(preset => (
          <Stack.Item key={preset.name}>
            <Button selected={chosen === preset.name} onClick={() => setChosen(preset.name)}>
              {preset.name}
            </Button>
          </Stack.Item>
        ))}
      </Stack>
      {current ? (
        <>
          <Box mt={1} style={{ whiteSpace: 'pre-wrap', fontFamily: 'monospace', fontSize: 11 }}>
            {current.text}
          </Box>
          <Button mt={1} icon="pen" content="Открыть в редакторе" onClick={() => onChoose(current.text)} />
        </>
      ) : (
        <Box mt={1} color="label" fontSize={11}>
          Выберите программу, чтобы увидеть её текст. Это данные: чужие права и старые адреса с ними не
          передаются.
        </Box>
      )}
    </Section>
  );
};

const ProgramsTab = ({
  actions,
  programs,
  presets,
  selected,
  onExecute,
  onImport,
}: {
  actions: ActionView[];
  programs: ProgramView[];
  presets: PresetView[];
  selected: number | null;
  onExecute: (action: string) => void;
  onImport: (text: string) => void;
}) => {
  const [text, setText] = useState(DEFAULT_SOURCE);
  return (
  <Stack vertical fill>
    <Stack.Item>
      <ProgramEditor text={text} onChange={setText} onRun={onImport} />
    </Stack.Item>
    <Stack.Item>
      <PresetLibrary presets={presets} onChoose={setText} />
    </Stack.Item>
    <Stack.Item>
      <Section title="Запущенные программы">
        <Table>
          <Table.Row header>
            <Table.Cell>ID</Table.Cell>
            <Table.Cell>Состояние</Table.Cell>
            <Table.Cell>Инструкций</Table.Cell>
            <Table.Cell>Причина</Table.Cell>
          </Table.Row>
          {programs.map(program => (
            <Table.Row key={program.process} className="candystripe">
              <Table.Cell>
                #{program.process} {program.definition}
              </Table.Cell>
              <Table.Cell>{programStateText[program.state] ?? program.state}</Table.Cell>
              <Table.Cell>{program.instructions}</Table.Cell>
              <Table.Cell color="label">{program.fault ?? '—'}</Table.Cell>
            </Table.Row>
          ))}
          {programs.length === 0 && (
            <Table.Row>
              <Table.Cell colSpan={4} color="label">
                Программ нет.
              </Table.Cell>
            </Table.Row>
          )}
        </Table>
      </Section>
    </Stack.Item>
    {actions.map(action => (
      <Stack.Item key={action.id}>
        <Section
          title={action.displayName}
          buttons={
            <Button
              icon="play"
              content="Выполнить"
              disabled={selected === null}
              tooltip={selected === null ? 'Сначала выберите хост' : undefined}
              onClick={() => onExecute(action.id)}
            />
          }
        >
          <Box color="label" fontSize={12}>
            {action.documentation}
          </Box>
          <Stack mt={1} wrap>
            <Stack.Item color="label" fontSize={11}>
              <Icon name="microchip" /> {action.computeCost} CU
            </Stack.Item>
            <Stack.Item color="label" fontSize={11}>
              <Icon name="memory" /> {action.memoryCost}
            </Stack.Item>
            <Stack.Item color="label" fontSize={11}>
              <Icon name="clock" /> {formatCooldown(action.cooldownMs)}
            </Stack.Item>
            <Stack.Item color="label" fontSize={11}>
              <Icon name="key" /> {action.capability}
            </Stack.Item>
            <Stack.Item color="label" fontSize={11}>
              {action.id}
            </Stack.Item>
          </Stack>
        </Section>
      </Stack.Item>
    ))}
  </Stack>
  );
};

const EventsTab = ({ operations }: { operations: OperationView[] }) => (
  <Table>
    <Table.Row header>
      <Table.Cell>Операция</Table.Cell>
      <Table.Cell>Итог</Table.Cell>
      <Table.Cell>Категория</Table.Cell>
      <Table.Cell>Причина</Table.Cell>
    </Table.Row>
    {operations.map(operation => (
      <Table.Row key={operation.operation} className="candystripe">
        <Table.Cell>#{operation.operation}</Table.Cell>
        <Table.Cell>{statusText[operation.status] ?? operation.status}</Table.Cell>
        <Table.Cell>{operation.category}</Table.Cell>
        <Table.Cell color="label">{operation.reason ?? '—'}</Table.Cell>
      </Table.Row>
    ))}
    {operations.length === 0 && (
      <Table.Row>
        <Table.Cell colSpan={4} color="label">
          Операций ещё не было.
        </Table.Cell>
      </Table.Row>
    )}
  </Table>
);

/**
 * The NETRUN client. One window, a sidebar of tabs and one task per screen (UI-001). The map is the working
 * area; the selected host is a compact context panel; the footer carries only a few real numbers. Every
 * value comes from one filtered server projection, so the client cannot show what the observer may not know.
 */
export const NetrunContent = ({
  data,
  act,
  tab,
  onTab,
  selected,
  onSelect,
}: {
  data: Data;
  act: Act;
  tab: TabKey;
  onTab: (key: TabKey) => void;
  selected: number | null;
  onSelect: (host: number | null) => void;
}) => {
  const panel = data.panel;
  const host = findHost(panel, selected);
  const hud = summarise(panel);

  const execute = (action: string) => {
    if (selected === null) {
      return;
    }
    act('execute', { action, target: selected });
  };

  return (
    <Stack fill>
      <Stack.Item>
        <Sidebar tab={tab} onTab={onTab} />
      </Stack.Item>
      <Stack.Item grow>
        <Stack vertical fill>
          <Stack.Item>
            {data.error ? (
              <NoticeBox danger>{data.error}</NoticeBox>
            ) : (
              !panel && <NoticeBox info>Нет данных: сеть ещё не отвечает.</NoticeBox>
            )}
            {data.notice && <NoticeBox info>{data.notice}</NoticeBox>}
          </Stack.Item>
          <Stack.Item grow>
            <Section fill scrollable title={TABS.find(entry => entry.key === tab)?.label}>
              {panel && tab === 'network' && (
                <NetrunMap
                  hosts={panel.hosts}
                  links={panel.links}
                  hideStale={false}
                  selected={selected}
                  onSelect={onSelect}
                />
              )}
              {panel && tab === 'hosts' && (
                <HostsTab hosts={panel.hosts} selected={selected} onSelect={onSelect} />
              )}
              {panel && tab === 'programs' && (
                <ProgramsTab
                  actions={panel.actions}
                  programs={panel.programs}
                  presets={panel.presets}
                  selected={selected}
                  onExecute={execute}
                  onImport={text => act('import', { source: text, target: selected })}
                />
              )}
              {panel && tab === 'life' && (
        <LifeTab
          core={panel.lives?.[0]}
          backups={panel.backups ?? []}
          presence={panel.presence ?? undefined}
          selected={selected}
          onLife={(action, target) => act('life', { action, target })}
          onRestore={backup => act('life', { action: 'restore_backup', backup, target: selected })}
        />
      )}
      {panel && tab === 'agents' && (
        <AgentsTab
          agents={panel.agents ?? []}
          selected={selected}
          onAgent={(action, extra) => act('agents', { action, ...extra })}
        />
      )}
      {panel && tab === 'events' && <EventsTab operations={panel.operations} />}
            </Section>
          </Stack.Item>
          <Stack.Item>
            <Box color="label" fontSize={11} px={1}>
              Хостов: {hud.hosts} · устаревших: {hud.stale} · действий: {hud.actions} · операций:{' '}
              {hud.operations}
            </Box>
          </Stack.Item>
        </Stack>
      </Stack.Item>
      {host && (
        <Stack.Item>
          <HostContext
            host={host}
            presence={panel?.presence ?? undefined}
            onExecute={execute}
            onTravel={() => {
              act('travel', {
                mode: panel?.presence ? 'move' : 'enter',
                target: selected,
              });
            }}
            onAbort={() => act('travel', { mode: 'abort' })}
          />
        </Stack.Item>
      )}
    </Stack>
  );
};

export const NetrunView = () => {
  const { data, act } = useBackend<Data>();
  return (
    <Window title="NETRUN" width={940} height={620}>
      <Window.Content>
        <NetrunWindow data={data} act={act} />
      </Window.Content>
    </Window>
  );
};

/** Keeps the view state in one place so the window and the tests share the same behaviour. */
export const NetrunWindow = ({ data, act }: { data: Data; act: Act }) => {
  const [tab, setTab] = useState<TabKey>('network');
  const [selected, setSelected] = useState<number | null>(null);
  return (
    <NetrunContent
      data={data}
      act={act}
      tab={tab}
      onTab={setTab}
      selected={selected}
      onSelect={setSelected}
    />
  );
};

export default NetrunView;
