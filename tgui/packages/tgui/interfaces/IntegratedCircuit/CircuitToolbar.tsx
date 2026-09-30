import { classes } from 'common/react';
import { ReactNode } from 'react';

import { Box, Button, Icon, Stack } from '../../components';
import type { IeCloneCopyMode } from './types';

export type CircuitToolbarProps = {
  circuitOn?: boolean;
  componentCount: number;
  variableCount?: number;
  zoomPercent: number;
  showVariableChip?: boolean;
  /** Wiremod cell charge % (null = no cell, undefined = field absent). */
  circuitCellPercent?: number | null;
  /** IE assembly battery charge % (null = no battery, undefined = field absent). */
  ieBatteryPercent?: number | null;
  ieCloneCopyMode?: IeCloneCopyMode | null;
  onIeCloneCopy?: () => void;
  onIeClassicUi?: () => void;
  onIePlaceChipCenter?: () => void;
  onEjectPowerCell?: () => void;
  onFitToView?: () => void;
  ieUsedSize?: number | null;
  ieMaxSize?: number | null;
  ieUsedComplexity?: number | null;
  ieMaxComplexity?: number | null;
};

type ChipTone = 'on' | 'off' | 'muted' | 'danger';

const Chip = (props: {
  icon: string;
  tone?: ChipTone;
  title?: string;
  children: ReactNode;
}) => {
  const { icon, tone = 'muted', title, children } = props;
  return (
    <Box
      className={classes([
        'IntegratedCircuit__chip',
        `IntegratedCircuit__chip--${tone}`,
      ])}
      title={title}>
      <Icon name={icon} />
      <span>{children}</span>
    </Box>
  );
};

/**
 * Верхняя панель: состояние платы, счётчики, лимиты корпуса и действия.
 * Ключевая информация слева, действия справа; без дублирующих подписей.
 */
export const CircuitToolbar = (props: CircuitToolbarProps) => {
  const {
    circuitOn,
    componentCount,
    variableCount = 0,
    zoomPercent,
    showVariableChip = true,
    circuitCellPercent,
    ieBatteryPercent,
    ieCloneCopyMode,
    onIeCloneCopy,
    onIeClassicUi,
    onIePlaceChipCenter,
    onEjectPowerCell,
    onFitToView,
    ieUsedSize,
    ieMaxSize,
    ieUsedComplexity,
    ieMaxComplexity,
  } = props;

  const powered = circuitOn !== false && circuitOn !== 0;
  const showIeLimits = typeof ieUsedSize === 'number'
    && typeof ieUsedComplexity === 'number';

  const sizeFull = typeof ieMaxSize === 'number' && ieUsedSize! >= ieMaxSize;
  const complexityFull = typeof ieMaxComplexity === 'number'
    && ieUsedComplexity! >= ieMaxComplexity;

  const limitSuffix = (used: number, max: number | null | undefined) =>
    typeof max === 'number' ? `${used} / ${max}` : String(used);

  return (
    <Box className="IntegratedCircuit__toolbar">
      <Stack align="center" justify="space-between" wrap>
        <Stack.Item>
          <Stack align="center" wrap>
            <Stack.Item>
              <Chip icon="power-off" tone={powered ? 'on' : 'off'}>
                {powered ? 'Вкл.' : 'Выкл.'}
              </Chip>
            </Stack.Item>
            <Stack.Item>
              <Chip icon="microchip">
                Компонентов: <b>{componentCount}</b>
              </Chip>
            </Stack.Item>
            {showIeLimits && (
              <Stack.Item>
                <Chip
                  icon="cubes"
                  tone={sizeFull ? 'danger' : 'muted'}
                  title="Сумма размеров микросхем / запас корпуса">
                  Размер {limitSuffix(ieUsedSize!, ieMaxSize)}
                </Chip>
              </Stack.Item>
            )}
            {showIeLimits && (
              <Stack.Item>
                <Chip
                  icon="project-diagram"
                  tone={complexityFull ? 'danger' : 'muted'}
                  title="Сумма сложности микросхем / лимит корпуса">
                  Сложность {limitSuffix(ieUsedComplexity!, ieMaxComplexity)}
                </Chip>
              </Stack.Item>
            )}
            {ieBatteryPercent !== undefined && (
              <Stack.Item>
                <Stack align="center">
                  <Chip
                    icon="battery-half"
                    title="Элемент питания в отсеке батареи">
                    Батарея{' '}
                    {ieBatteryPercent === null ? 'нет' : `${ieBatteryPercent}%`}
                  </Chip>
                  {ieBatteryPercent !== null && onEjectPowerCell && (
                    <Button
                      icon="eject"
                      color="transparent"
                      compact
                      tooltip="Извлечь батарею"
                      onClick={onEjectPowerCell}
                    />
                  )}
                </Stack>
              </Stack.Item>
            )}
            {circuitCellPercent !== undefined && (
              <Stack.Item>
                <Stack align="center">
                  <Chip icon="battery-half">
                    Ячейка{' '}
                    {circuitCellPercent === null ? 'нет' : `${circuitCellPercent}%`}
                  </Chip>
                  {circuitCellPercent !== null && onEjectPowerCell && (
                    <Button
                      icon="eject"
                      color="transparent"
                      compact
                      tooltip="Извлечь ячейку"
                      onClick={onEjectPowerCell}
                    />
                  )}
                </Stack>
              </Stack.Item>
            )}
            {showVariableChip && (
              <Stack.Item>
                <Chip icon="database">
                  Переменных: <b>{variableCount}</b>
                </Chip>
              </Stack.Item>
            )}
          </Stack>
        </Stack.Item>
        <Stack.Item>
          <Stack align="center">
            {onFitToView && (
              <Stack.Item>
                <Button
                  icon="expand"
                  color="transparent"
                  compact
                  tooltip="Вписать все компоненты в поле"
                  onClick={onFitToView}>
                  Показать всё
                </Button>
              </Stack.Item>
            )}
            <Stack.Item>
              <Chip icon="search-plus" title="Текущий масштаб поля">
                {zoomPercent}%
              </Chip>
            </Stack.Item>
            {(ieCloneCopyMode === 'assembly' || ieCloneCopyMode === 'chip')
              && onIeCloneCopy && (
                <Stack.Item>
                  <Button
                    icon="copy"
                    color="transparent"
                    compact
                    tooltip={
                      ieCloneCopyMode === 'assembly'
                        ? 'JSON сборки для принтера'
                        : 'JSON одного чипа'
                    }
                    onClick={onIeCloneCopy}>
                    Код
                  </Button>
                </Stack.Item>
              )}
            {onIeClassicUi && (
              <Stack.Item>
                <Button
                  icon="window-restore"
                  color="transparent"
                  compact
                  tooltip="Классический интерфейс"
                  onClick={onIeClassicUi}>
                  Классика
                </Button>
              </Stack.Item>
            )}
            {onIePlaceChipCenter && (
              <Stack.Item>
                <Button
                  icon="crosshairs"
                  color="transparent"
                  compact
                  tooltip="Вставить чип из руки в центр вида (Shift+ЛКМ — в точку клика)"
                  onClick={onIePlaceChipCenter}>
                  Чип сюда
                </Button>
              </Stack.Item>
            )}
          </Stack>
        </Stack.Item>
      </Stack>
    </Box>
  );
};