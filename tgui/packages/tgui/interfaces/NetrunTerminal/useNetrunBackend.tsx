import { createContext, ReactNode, useCallback, useContext, useEffect, useLayoutEffect, useRef, useState, useSyncExternalStore } from 'react';

import { useBackend } from '../../backend';
import { NetrunActionFeedback } from './actionFeedback';
import { NetrunData } from './types';

const FeedbackContext = createContext<NetrunActionFeedback | null>(null);
const NO_FEEDBACK = () => null;
const NO_SUBSCRIPTION = () => () => {};

const LABELS: Record<string, string> = {
  select: 'Выбор узла', select_network: 'Выбор сети', focus_host: 'Возврат к своему узлу',
  map_sector: 'Смена сектора или этажа', map_resync: 'Синхронизация карты', search: 'Поиск узлов',
  breach: 'Начало взлома', breach_pick: 'Выбор кода', breach_abort: 'Прерывание взлома',
  hop: 'Переход в узел', relay_hop: 'Переход через реле', travel: 'Автопроход', travel_cancel: 'Остановка маршрута',
  file_new: 'Создание файла', file_edit: 'Сохранение файла', file_rename: 'Переименование файла',
  file_copy: 'Копирование файла', file_move: 'Перенос файла', file_select: 'Выбор файла',
  delete_local: 'Удаление файла', delete_remote: 'Удаление файла с устройства',
  read: 'Чтение файла', upload: 'Загрузка файла', download: 'Скачивание файла',
  window_open: 'Открытие устройства', window_close: 'Закрытие устройства', window_focus: 'Выбор устройства',
  set_waypoint: 'Построение маршрута', clear_waypoint: 'Сброс маршрута',
  program_use: 'Запуск программы', recover_salvage: 'Подбор данных', chat_send: 'Отправка сообщения',
  cli: 'Команда терминала', web_site: 'Открытие сайта', web_page: 'Открытие страницы', web_back: 'Навигация WEB',
};

const actionLabel = (action: string, params: Record<string, unknown>, data: NetrunData) => {
  if (action === 'command' || action === 'window_act') {
    const id = action === 'command' ? params.id : params.waction;
    const commands = action === 'command' ? data.selected?.commands : data.window?.commands;
    return commands?.find((entry) => entry.id === id)?.name || 'Команда устройства';
  }
  if (action === 'remote_act') {
    const actions = data.window?.remote && data.window.remote.actions;
    return (Array.isArray(actions) && actions.find((entry) => entry.id === params.request)?.name) || 'Управление устройством';
  }
  return LABELS[action] || (Array.isArray(data.host_actions) && data.host_actions.find((entry) => entry.id === action)?.name) || 'Действие в сети';
};

export const NetrunFeedbackProvider = ({ children }: { children: ReactNode }) => {
  const { data } = useBackend<NetrunData>();
  const [feedback] = useState(() => new NetrunActionFeedback());
  useLayoutEffect(() => { feedback.acknowledge(data.input_ack); }, [feedback, data.input_ack]);
  useEffect(() => () => feedback.dispose(), [feedback]);
  return <FeedbackContext.Provider value={feedback}>{children}</FeedbackContext.Provider>;
};

export const useNetrunFeedback = () => {
  const feedback = useContext(FeedbackContext);
  return useSyncExternalStore(feedback?.subscribe || NO_SUBSCRIPTION, feedback?.snapshot || NO_FEEDBACK, NO_FEEDBACK);
};

/** Same backend contract for every NetRun host, with a local receipt before transport.
 * No provider is required by standalone panels or other games' interfaces.
 */
export const useNetrunBackend = <TData extends NetrunData = NetrunData>() => {
  const backend = useBackend<TData>();
  const latest = useRef(backend); latest.current = backend;
  const feedback = useContext(FeedbackContext);
  const act = useCallback((action: string, payload: object = {}) => {
    if (!feedback || action === 'workspace_view' || action === 'set_handle' || action === 'map_sync_ack') {
      return latest.current.act(action, payload);
    }
    const nonce = feedback.begin(action, payload, actionLabel(action, payload as Record<string, unknown>, latest.current.data));
    return latest.current.act(action, { ...payload, _netrun_action: nonce });
  }, [feedback]);
  return { ...backend, act };
};
