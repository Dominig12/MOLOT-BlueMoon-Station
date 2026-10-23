# PixiJS в NetRun — ограниченный экспериментальный движок

**По умолчанию работает старый Canvas.** Просто импорт `pixiSurface.ts` не загружает PixiJS,
не создаёт GPU-контекстов и не запускает анимаций. В браузерах BYOND/CEF WebGL2
может быть недоступен: обязательно используйте запасной Canvas-путь.

Установленная зависимость: `pixi.js@8.22.0`, находится в рабочем пространстве
`tgui/packages/tgui`. Вызывать `mountNetrunPixi` нужно **только при явном переключении**
на аппаратный рендерер (например, в будущем переключателе в настройках карты).

```tsx
import { mountNetrunPixi, pixiWithinBudget } from './pixiSurface';

// В React effect, с проверкой isCancelled и cleanup:
const surface = await mountNetrunPixi(container, width, height, fallbackToCanvas);
if (surface && surface.updateScene(stationaryGraph)) {
  surface.updateCamera(graphViewport);
  // При изменении камеры: surface.updateCamera(graphViewport).
  // При изменении геометрии: surface.updateScene(newGraphScene).
  // При изменении размера: surface.resize(width, height) || fallbackToCanvas().
}
// При размонтировании либо переключении: surface?.destroy().
```

### Защита клиента

- Ленивая загрузка: отдельный кусок кода Vite; в стандартном режиме PixiJS не загружается.
- WebGL2 с низким энергопотреблением; если инициализация провалилась — возврат `null`.
- Ограничение до **2000 узлов, 5000 связей, 2 млн пикселей**. При превышении `updateScene`
  возвращает `false`; вызывающая сторона обязана использовать Canvas.
- Частота рисования не более **30 кадров/с**, только при изменении данных, камеры
  или размеров. Pixi ticker остановлен; нет постоянного игрового цикла.
- Нет текстур, фильтров, эффектов и отдельных отображаемых объектов на каждый узел.
- `destroy()` освобождает GPU-ресурсы, обработчики событий и отложенный кадр.
- Нет поддержки всех визуальных слоёв карты (области APC, подписи,
  динамические маркеры, маршрут): модуль предназначен как фундамент для
  дальнейшего постепенного переноса, **не как готовая замена GraphCanvas**.

После обновления зависимостей проекта выполните из `tgui/`:
```sh
yarn install
yarn tgui:tsc
yarn tgui:test-simple --runInBand
```
