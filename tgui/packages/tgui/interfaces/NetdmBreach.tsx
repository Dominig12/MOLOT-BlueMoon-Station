import { BooleanLike } from 'common/react';
import { useEffect, useState } from 'react';

import { Box, Button, Icon, Stack } from '../components';

export type HackState = {
  status?: string | null;
  code?: string | null;
  target?: string | null;
  remaining?: number;
  keys?: { node: string; label: string; ttl: number }[] | null;
  masked?: BooleanLike;
};

const SIGNALS = [
  { icon: 'bolt', label: 'Молния' },
  { icon: 'circle', label: 'Круг' },
  { icon: 'square', label: 'Квадрат' },
  { icon: 'star', label: 'Звезда' },
  { icon: 'moon', label: 'Луна' },
  { icon: 'heart', label: 'Сердце' },
  { icon: 'leaf', label: 'Лист' },
  { icon: 'gem', label: 'Кристалл' },
];
const BREACH_MESSAGES: Record<string, string> = {
  waiting: 'Запрашиваем сигнал…',
  checking: 'Проверяем последовательность…',
  failed: 'Система заметила попытку. Дождитесь перезарядки.',
  cooldown: 'Взлом на перезарядке.',
  expired: 'Время вышло.',
  no_answer: 'Нет ответа от сети.',
  no_knowledge: 'Сначала просканируйте область.',
  busy: 'Сеть занята. Попробуйте ещё раз.',
};

const SignalCipher = ({ code, remaining, enabled, submit }: {
  code: string; remaining: number; enabled: boolean; submit: (answer: string) => void;
}) => {
  const [startedAt] = useState(Date.now);
  const [now, setNow] = useState(startedAt);
  const [answer, setAnswer] = useState('');
  const [sent, setSent] = useState(false);
  const [deadline] = useState(() => startedAt + remaining * 1000);
  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), 100);
    return () => window.clearInterval(timer);
  }, []);
  const seconds = Math.ceil((deadline - now) / 1000);
  if (seconds <= 0 || remaining <= 0) {
    return <Box role="status" color="average">Время вышло.</Box>;
  }
  if (sent) {
    return <Box role="status" color="label">Проверяем последовательность…</Box>;
  }
  const preview = now - startedAt < 2300;
  const alphabet = [...new Set(code)].sort();
  const decoys = [...'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'].filter(letter => !alphabet.includes(letter));
  const choices = [...alphabet, ...decoys.slice(0, SIGNALS.length - alphabet.length)]
    .sort((first, second) => (first.charCodeAt(0) * 17 % 37) - (second.charCodeAt(0) * 17 % 37));
  return (
    <div className="NetdmBreach__cipher">
      <Stack justify="space-between">
        <Stack.Item><Box bold>{preview ? 'Запомните сигнал' : 'Повторите сигнал'}</Box></Stack.Item>
        <Stack.Item><Box color={seconds <= 4 ? 'average' : 'label'}>{seconds} с</Box></Stack.Item>
      </Stack>
      <div className="NetdmBreach__sequence" aria-label={preview ? 'Сигнал' : 'Ваш ответ'}>
        {[...code].map((letter, index) => {
          const signal = SIGNALS[choices.indexOf(preview ? letter : answer[index])];
          return signal ? (
            <span key={index} className="NetdmBreach__tile" role="img" aria-label={signal.label}>
              <Icon name={signal.icon} />
            </span>
          ) : <span key={index} />;
        })}
      </div>
      {!preview && (
        <>
          <div className="NetdmBreach__choices" aria-label="Варианты сигнала">
            {choices.map((letter, index) => (
              <Button key={letter} role="button" icon={SIGNALS[index].icon} aria-label={SIGNALS[index].label}
                tooltip={SIGNALS[index].label} disabled={!enabled || answer.length >= code.length}
                onClick={() => setAnswer(previous => previous.length < code.length ? previous + letter : previous)} />
            ))}
          </div>
          <Stack>
            <Stack.Item><Button icon="undo" disabled={!answer} onClick={() => setAnswer('')}>Сбросить</Button></Stack.Item>
            <Stack.Item>
              <Button icon="check" color="good" disabled={!enabled || answer.length !== code.length}
                onClick={() => {
                  if (Date.now() < deadline) {
                    setSent(true);
                    submit(answer);
                  }
                }}>Ответить
              </Button>
            </Stack.Item>
          </Stack>
        </>
      )}
    </div>
  );
};

export const NetdmBreach = ({ hack, selected, enabled, onStart, onAnswer, onUse }: {
  hack?: HackState | null;
  selected: string;
  enabled: boolean;
  onStart: () => void;
  onAnswer: (answer: string) => void;
  onUse: () => void;
}) => {
  const key = hack?.keys?.find(item => item.node === selected && item.ttl > 0);
  const isTarget = hack?.target === selected;
  const code = isTarget && hack?.status === 'challenge' && hack.code && /^[A-HJ-NP-Z2-9]{6}$/.test(hack.code)
    ? hack.code : null;
  const busy = hack?.status === 'waiting' || hack?.status === 'checking' ||
    (hack?.status === 'challenge' && (hack.remaining ?? 0) > 0);
  const message = isTarget && hack?.status ? BREACH_MESSAGES[hack.status] : null;
  return (
    <>
      {key ? (
        <Stack align="center" wrap>
          <Stack.Item grow><Box color="good">Ключ доступа получен</Box></Stack.Item>
          <Stack.Item>
            <Button.Confirm icon="power-off" content="Переключить питание"
              confirmContent="Переключить автомат АПЦ?" disabled={!enabled} onClick={onUse} />
          </Stack.Item>
        </Stack>
      ) : (
        <Button icon="unlock-alt" disabled={!enabled || busy} onClick={onStart}>Взломать АПЦ</Button>
      )}
      {code && (
        <SignalCipher key={code} code={code} remaining={hack?.remaining ?? 0} enabled={enabled} submit={onAnswer} />
      )}
      {!!message && <Box mt={0.5} color="label" role="status">{message}</Box>}
    </>
  );
};
