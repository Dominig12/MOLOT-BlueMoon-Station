import { KeyboardEvent, ReactNode, useId } from 'react';

import { Icon } from '../components';

const TABS = [
  { id: 'node', icon: 'microchip', label: 'Узел' },
  { id: 'route', icon: 'route', label: 'Маршруты' },
  { id: 'activity', icon: 'stream', label: 'События' },
  { id: 'operator', icon: 'user-astronaut', label: 'Оператор' },
  { id: 'chat', icon: 'comments', label: 'Чат' },
] as const;

export type SpaceTab = typeof TABS[number]['id'];

export const NetdmSpaceDock = ({ tab, onTab, title, unread, routeActive, children }: {
  tab: SpaceTab;
  onTab: (tab: SpaceTab) => void;
  title?: string;
  unread: number;
  routeActive: boolean;
  children: ReactNode;
}) => {
  const id = useId();
  const handleKey = (event: KeyboardEvent<HTMLButtonElement>, index: number) => {
    const next = {
      ArrowDown: (index + 1) % TABS.length,
      ArrowUp: (index + TABS.length - 1) % TABS.length,
      Home: 0,
      End: TABS.length - 1,
    }[event.key];
    if (next === undefined) return;
    event.preventDefault();
    event.stopPropagation();
    event.currentTarget.parentElement?.querySelectorAll('button')[next]?.focus();
    onTab(TABS[next].id);
  };
  return (
    <div className="NetdmDock" data-tab={tab}>
      <div className="NetdmDock__rail" role="tablist" aria-label="Панели сети" aria-orientation="vertical">
        {TABS.map((item, index) => {
          const unreadChat = item.id === 'chat' && unread > 0;
          const label = unreadChat ? `Чат, непрочитанных сообщений ${unread}` : item.label;
          return (
            <button key={item.id} id={`${id}-${item.id}-tab`} type="button" role="tab"
              className="NetdmDock__tab" data-tab={item.id} aria-label={label}
              aria-controls={`${id}-${item.id}-panel`} aria-selected={tab === item.id}
              tabIndex={tab === item.id ? 0 : -1} title={label}
              onClick={() => onTab(item.id)} onKeyDown={event => handleKey(event, index)}>
              <Icon name={item.icon} />
              {unreadChat && (
                <span aria-hidden="true" className="NetdmDock__unread">{unread > 99 ? '99+' : unread}</span>
              )}
              {item.id === 'route' && routeActive && (
                <span aria-hidden="true" className="NetdmDock__routeDot" />
              )}
            </button>
          );
        })}
      </div>
      {TABS.map(item => (
        <section key={item.id} id={`${id}-${item.id}-panel`} role="tabpanel"
          aria-labelledby={`${id}-${item.id}-tab`} hidden={item.id !== tab} tabIndex={0}
          className="NetdmDock__panel">
          {item.id === tab && (
            <>
              <header className="NetdmDock__header">
                <span className="NetdmDock__headerIcon" aria-hidden="true"><Icon name={item.icon} /></span>
                <h2>{title || item.label}</h2>
              </header>
              <div className={`NetdmDock__body NetdmDock__body--${item.id}`}>{children}</div>
            </>
          )}
        </section>
      ))}
    </div>
  );
};
