<p align="center">
  <img src="assets/logo.png" width="200" alt="continuum">
</p>

<h1 align="center">continuum</h1>

<p align="center">
  <b><a href="README.md">🇷🇺 English </a></b>  | <b>🇷🇺 Русский</b>
</p>

<p align="center">
  Видишь лимит заранее. Решаешь, что делать. Продолжаешь автоматически после сброса.
</p>

<p align="center">
  <a href="https://github.com/TropinAlexey/continuum/releases"><img src="https://img.shields.io/badge/version-0.5.0-brightgreen.svg" alt="version: 0.5.0"></a>
  <a href="https://github.com/TropinAlexey/continuum/actions/workflows/ci.yml"><img src="https://github.com/TropinAlexey/continuum/actions/workflows/ci.yml/badge.svg" alt="ci"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="license: MIT"></a>
</p>

---

У AI-агентов есть лимиты использования на временное окно. Когда лимит кончается посреди задачи — сессия встаёт, и ты ждёшь сброса сам. **continuum** следит за бюджетом, предупреждает заранее, и — если выберешь — засыпает до сброса и возобновляет сессию автоматически.

## Установка

**CLI** (работает с любым агентом):

```sh
# Mac / Linux / BSD
curl -fsSL https://raw.githubusercontent.com/TropinAlexey/continuum/main/install.sh | sh

# Windows (PowerShell)
irm https://raw.githubusercontent.com/TropinAlexey/continuum/main/install.ps1 | iex
```

**Плагин Claude Code** (автоматические предупреждения — Claude сам останавливается на пороге и спрашивает что делать):

```
/plugin marketplace add TropinAlexey/continuum
/plugin install continuum
```

Ставь оба для полного эффекта: CLI для команды, плагин для автоматики. Не конфликтуют.

> Скрипты короткие — прочти [install.sh](install.sh) / [install.ps1](install.ps1) перед запуском, если хочешь.

### ⚠️ Перед установкой

-   **Недокументированный эндпоинт.** Провайдер `anthropic` вызывает `https://api.anthropic.com/api/oauth/usage` — не публичный API, может измениться. Токен идёт в одном заголовке `curl` на один хост. Несколько сотен строк шелла — читай.
-   **`continuum resume` запускает Claude без присмотра** с `--permission-mode acceptEdits`. Делай промпт узким. Не направляй на то, что не дал бы мержить незнакомцу.

## Что происходит

Когда утилизация пересекает порог, Claude останавливается и спрашивает:

> *Окно заполнено на 86%, сбрасывается в 21:40. Что делаем?*

Варианты: свернуться, доделать текущий пакет, сохранить и авто-resume, экономный режим (блокирует субагентов), только дешёвые задачи, или проигнорировать. Спрашивает на твоём языке. Предупреждения ступенчатые — **80% → 90% → 95% → 99%** — каждый уровень срабатывает один раз. Недельное окно отдельно (**70% → 85% → 95%**).

Выбрал «сохранить и продолжить» → коммитит, планирует `claude --continue` на после сброса, отдаёт PID. Закрываешь ноутбук. Сессия продолжает без тебя.

## Использование

```sh
continuum status      # 5 hours   86.5%   resets at 21:40
                      # 7 days    41.0%   resets at 02:00
continuum reset       # 21:41   (reset +90s, готово для планирования)
continuum estimate    # при таком темпе ещё ~2ч 15м
continuum watch       # поллинг в отдельной панели; звонок на пороге
continuum history     # последние 20 снапшотов
continuum cleanup     # удалить устаревшие файлы (>24ч)
continuum providers   # anthropic, mock, spend

continuum resume "$(continuum reset)" "$PWD" "доделать тесты DocumentService"
```

**Другие агенты:** `continuum watch` и `continuum resume` работают без плагина:

```sh
CONTINUUM_RESUME_CMD='codex exec "{prompt}"'    continuum resume 21:41 "$PWD" "finish the tests"
CONTINUUM_RESUME_CMD='opencode run "{prompt}"'  continuum resume 21:41 "$PWD" "finish the tests"
```

См. [docs/harnesses.md](docs/harnesses.md) — что проверено.

## Как работает

Claude Code запускает `Stop`-хук после каждого хода. Хук, который печатает `{"decision":"block","reason":"..."}`, отправляет reason обратно модели вместо завершения хода. Вот и весь трюк.

Пять деталей:

1.  **Провайдер** (`providers/anthropic.sh`) — `curl` к эндпоинту, печатает `5h 86.5 1783000000` (окно, процент, epoch сброса). Три колонки — весь контракт провайдера.
2.  **Stop-хук** (`hooks/continuum-check.sh`) — вызывает провайдера через 10-минутный кэш (позитивный и негативный), сравнивает с тирами, печатает блокирующий JSON. Проверяет `stop_hook_active` первым (иначе бесконечный цикл). Флаг по сессии — каждый тир один раз.
3.  **PreToolUse-хук** (`hooks/frugal-gate.sh`) — в экономном режиме (`CONTINUUM_FRUGAL=1`) блокирует `Agent` на уровне хука.
4.  **Скилл** (`skills/session-budget`) — то, что reason просит Claude запустить. Показывает ситуацию, предлагает варианты через `AskUserQuestion`. Не решает за тебя.
5.  **`continuum resume`** — планирует `claude --continue -p "$PROMPT"` на после сброса. Выбирает лучший планировщик ОС, не даёт системе заснуть, уведомляет по завершению.

## Resume

`continuum resume` выбирает лучший планировщик и предотвращает засыпание системы:

ОС

Планировщик

Переживает ребут

Wakelock

macOS

`launchd`

да

`caffeinate -i`

Linux

`systemd-run --user`

да

`systemd-inhibit`

FreeBSD

`daemon(8)`

только logout

—

Windows

detached process

нет

`SetThreadExecutionState`

Fallback

`nohup sleep`

нет

лучший доступный

Лог: `~/.claude/continuum-resume.log` — маркеры `### resumed in DIR` / `### end (exit N)`. Десктопное уведомление по завершению (`osascript` / `notify-send`).

## Статуслайн

Процент использования в статусной строке Claude Code: **зелёный** (<80%), **жёлтый** (80–94%), **красный** (≥95%). Обновляется каждые ~30с.

```json
{
  "statusLine": {
    "type": "command",
    "command": "sh "$HOME/.claude/hooks/statusline.sh""
  }
}
```

При установке плагина скрипт копируется автоматически.

## Провайдеры

continuum провайдер-агностичен — спрашивает «сколько использовано, когда сброс» и не знает откуда данные.

Провайдер — скрипт, который печатает: `5h 86.5 1783000000` — вот и весь интерфейс. Написать свой за 10 минут: [docs/writing-a-provider.md](docs/writing-a-provider.md).

**Несколько провайдеров:** `CONTINUUM_PROVIDER=anthropic,spend` — запускает оба, берёт максимальную утилизацию.

## Платформы

macOS, Linux, FreeBSD/OpenBSD/NetBSD, Windows (Git Bash или PowerShell). POSIX `sh` + `curl`, без зависимостей. CI тестирует `.sh` и `.ps1` на всех платформах.

Windows без Git Bash — переопредели хуки в `settings.json`:

```json
{
  "hooks": {
    "Stop": [{ "hooks": [{
      "type": "command",
      "command": "pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/hooks/continuum-check.ps1"",
      "shell": "powershell"
    }]}],
    "PreToolUse": [{ "hooks": [{
      "type": "command",
      "command": "pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/hooks/frugal-gate.ps1"",
      "shell": "powershell"
    }]}]
  }
}
```

## Настройка

Переменная

По умолчанию

Что делает

`CONTINUUM_THRESHOLD`

`80`

Порог основного окна (%).

`CONTINUUM_TIERS`

`80 90 95 99`

Уровни основного окна. Каждый — один раз.

`CONTINUUM_THRESHOLD_7D`

`70`

Порог недельного окна.

`CONTINUUM_TIERS_7D`

`70 85 95`

Уровни недельного окна.

`CONTINUUM_PROVIDER`

`anthropic`

Провайдер(ы), через запятую.

`CONTINUUM_RESUME_CMD`

`claude --continue …`

Команда агента для `resume`. `{prompt}` = задача.

`CONTINUUM_DRY_RUN`

—

`resume` печатает вместо планирования.

`CONTINUUM_OFF`

—

Отключить Stop-хук.

`CONTINUUM_FRUGAL`

—

`1` = экономный режим: блокирует Agent.

`CONTINUUM_CACHE_MIN`

`10`

Время кэша (минуты). `0` отключает.

`CONTINUUM_SPEND_CAP`

`100`

Месячный бюджет ($) для провайдера `spend`.

`ANTHROPIC_ADMIN_KEY`

—

Admin API ключ для провайдера `spend`.

## Troubleshooting

**Ничего на 80%.** Хук срабатывает только на `Stop`. Запусти `sh tests/run.sh`. Проходит → плагин не загружен, проверь `/plugin`.

**`usage endpoint unavailable`.** Оффлайн, рейт-лимит (подожди 10 мин), или токен истёк. Перелогинься в Claude Code.

**`no OAuth token found`.** Не залогинен или credentials не там. Экспортируй `CLAUDE_CODE_OAUTH_TOKEN`.

**`continuum resume` не сработал.** Проверь `~/.claude/continuum-resume.log`. macOS: `launchctl list | grep continuum`. Linux: `systemctl --user list-timers | grep continuum`.

**Предупреждение есть, Claude игнорирует.** Понизь `CONTINUUM_THRESHOLD`.

## Участие

```
sh tests/run.sh          # 55 тестов, mock-провайдер, без сети
pwsh tests/run.ps1       # тот же набор для PowerShell
```

Что помогло бы: провайдер для другого бюджета (OpenAI, Gemini — см. [docs/writing-a-provider.md](docs/writing-a-provider.md)), подтверждение работы `Stop`-хука в Codex CLI ([docs/harnesses.md](docs/harnesses.md)).

## Удаление

```
/plugin uninstall continuum
rm -f /usr/local/bin/continuum
rm -f ~/.claude/.continuum-cache-* ~/.claude/.continuum-warned-* ~/.claude/.continuum-warned7d-* ~/.claude/.continuum-wakelock-* ~/.claude/.continuum-history.log
```

Или: `continuum cleanup` удалит только устаревшие файлы (>24ч).

## Лицензия

MIT
