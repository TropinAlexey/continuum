<p align="center">
  <img src="assets/logo.png" width="200" alt="continuum">
</p>

<h1 align="center">continuum</h1>

<p align="center">
  <b><a href="README.md">🇬🇧 English</a></b>  | <b>🇷🇺 Русский</b>
</p>

<p align="center">
  Видишь лимит заранее. Решаешь, что делать. Продолжаешь автоматически после сброса.
</p>

<p align="center">
  <a href="https://github.com/TropinAlexey/continuum/releases"><img src="https://img.shields.io/badge/version-0.6.0-brightgreen.svg" alt="version: 0.6.0"></a>
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

Когда утилизация пересекает порог, твой агент останавливается и спрашивает:

> *Окно заполнено на 86%, сбрасывается в 21:40. Что делаем?*

Варианты: свернуться, доделать текущий пакет, сохранить и авто-resume, экономный режим (блокирует субагентов), только дешёвые задачи, или проигнорировать. Спрашивает на твоём языке. Предупреждения ступенчатые — **80% → 90% → 95% → 99%** — каждый уровень срабатывает один раз. Недельное окно отдельно (**70% → 85% → 95%**). Если использование упало обратно ниже порога (докупка лимита или переворот окна), уровни взводятся заново и сработают снова на росте.

Выбрал «сохранить и продолжить» → коммитит, планирует запуск твоего агента (по умолчанию `claude --continue`) на после сброса, отдаёт PID. Закрываешь ноутбук. Сессия продолжает без тебя.

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
continuum check       # печатает предупреждение при пересечении нового тира, иначе ничего
continuum statusline  # показать конфиг статуслайна

continuum resume "$(continuum reset)" "$PWD" "доделать тесты DocumentService"
```

## Агенты

continuum не привязан к агенту: ядро (`bin/`, `lib/`, `providers/`) никогда не спрашивает, какой агент его вызвал. У каждого агента свой тонкий адаптер в `adapters/<агент>/`, который переводит протокол хуков в `continuum check` и обратно.

| Агент | Предупреждение в сессии | Пресет resume | Статус |
|---|---|---|---|
| **Claude Code** | `Stop`-хук → `adapters/claude/` | `CONTINUUM_AGENT=claude` (по умолчанию) | Поддерживается, тестируется в CI |
| Codex CLI, opencode, Cursor, Gemini CLI | адаптеры в планах | задай `CONTINUUM_RESUME_CMD` | Пока — `continuum check` / `continuum watch` |
| Любой другой | `continuum check` из хука или `continuum watch` в отдельной панели | задай `CONTINUUM_RESUME_CMD` | Работает уже сейчас |

```sh
CONTINUUM_RESUME_CMD='codex exec "{prompt}"'    continuum resume 21:41 "$PWD" "finish the tests"
CONTINUUM_RESUME_CMD='opencode run "{prompt}"'  continuum resume 21:41 "$PWD" "finish the tests"
```

Агент и провайдер независимы: сессия Codex может следить за окном Anthropic, и наоборот. Что проверено и как написать адаптер — [docs/harnesses.md](docs/harnesses.md).

## Как работает

Агенты с хуками запускают хук после каждого хода. В Claude Code `Stop`-хук, который печатает `{"decision":"block","reason":"..."}`, отправляет reason обратно модели вместо завершения хода. Вот и весь трюк.

```
событие агента ──► adapters/<агент>/ ──► continuum check ──► провайдер
                   (протокол агента)     (тиры, кэш,         (usage, сброс)
                                          флаги, текст)
```

1.  **Провайдер** (`providers/anthropic.sh`) — `curl` к эндпоинту, печатает `5h 86.5 1783000000` (окно, процент, epoch сброса). Три колонки — весь контракт провайдера.
2.  **`continuum check`** — агент-нейтральное ядро предупреждения: вызывает провайдера через 10-минутный кэш (позитивный и негативный), сравнивает с тирами, печатает текст предупреждения или ничего. Флаг по сессии — каждый тир один раз.
3.  **Адаптер** (`adapters/claude/stop.sh`) — превращает `Stop`-событие Claude в `continuum check --session … --agent claude`, а текст — в блокирующий JSON. Проверяет `stop_hook_active` первым (иначе бесконечный цикл).
4.  **Frugal gate** (`adapters/claude/frugal-gate.sh`) — в экономном режиме (`CONTINUUM_FRUGAL=1`) блокирует `Agent` на уровне хука.
5.  **Скилл** (`skills/session-budget`) — то, что предупреждение просит агента запустить. Показывает ситуацию, спрашивает пользователя (в Claude Code — через `AskUserQuestion`). Не решает за тебя.
6.  **`continuum resume`** — планирует headless-команду твоего агента на после сброса. Выбирает лучший планировщик ОС, не даёт системе заснуть, уведомляет по завершению.

Состояние (кэш, флаги, логи, конфиг статуслайна, свои провайдеры) живёт в собственном каталоге continuum: `$CONTINUUM_STATE_DIR`, иначе `$XDG_STATE_HOME/continuum`, иначе `~/.local/state/continuum`. При первом запуске continuum копирует свои старые файлы из `~/.claude` (оригиналы остаются).

## Resume

`continuum resume` выбирает лучший планировщик и предотвращает засыпание системы:

| OS | Планировщик | Переживает ребут | Wakelock |
|---|---|---|---|
| macOS | `launchd` | да | `caffeinate -i` |
| Linux | `systemd-run --user` | да | `systemd-inhibit` |
| FreeBSD | `daemon(8)` | только logout | — |
| Windows | detached process | нет | `SetThreadExecutionState` |
| Fallback | `nohup sleep` | нет | лучший доступный |

Лог: `continuum-resume.log` в каталоге состояния — маркеры `### resumed in DIR` / `### end (exit N)`. Десктопное уведомление по завершению (`osascript` / `notify-send`).

## Статуслайн

Процент использования в статусной строке Claude Code: **зелёный** (<80%), **жёлтый** (80–94%), **красный** (≥95%). Обновляется каждые ~30с.

```json
{
  "statusLine": {
    "type": "command",
    "command": "sh \"$HOME/.claude/hooks/statusline.sh\""
  }
}
```

При установке плагина скрипт копируется автоматически (CLI-инсталлятор тоже включает его в `settings.json`, создавая файл если его нет).

Windows (PowerShell): в качестве команды `statusLine` используй `adapters/claude/statusline.ps1`, настройка — через `continuum.ps1 statusline`, ключи те же.

Настройка формата — токены `{d%}` дневной %, `{w%}` недельный %, `{dr}` сброс дневного, `{wr}` сброс недельного:

```sh
continuum statusline                    # показать текущий конфиг
continuum statusline format "{d%}% d {dr} | {w%}% w {wr}"
continuum statusline format-single "{d%}% d {dr}"   # когда окно только одно
continuum statusline time "%H:%M"       # формат времени сброса
continuum statusline date "%d.%m"       # формат даты сброса (когда не сегодня)
continuum statusline today "today"      # слово для сегодняшнего сброса
continuum statusline reset              # вернуть defaults
```

## Провайдеры

continuum провайдер-агностичен — спрашивает «сколько использовано, когда сброс» и не знает откуда данные.

Провайдер — скрипт, который печатает: `5h 86.5 1783000000` — вот и весь интерфейс. Написать свой за 10 минут: [docs/writing-a-provider.md](docs/writing-a-provider.md).

**Несколько провайдеров:** `CONTINUUM_PROVIDER=anthropic,spend` — запускает оба, берёт максимальную утилизацию (пробелы вокруг запятой допустимы).

## Платформы

macOS, Linux, FreeBSD/OpenBSD/NetBSD, Windows (Git Bash или PowerShell). POSIX `sh` + `curl`, без зависимостей. CI тестирует `.sh` и `.ps1` на всех платформах.

Windows без Git Bash — переопредели хуки в `settings.json`:

```json
{
  "hooks": {
    "Stop": [{ "hooks": [{
      "type": "command",
      "command": "pwsh -NoProfile -File \"${CLAUDE_PLUGIN_ROOT}/adapters/claude/stop.ps1\"",
      "shell": "powershell"
    }]}],
    "PreToolUse": [{ "hooks": [{
      "type": "command",
      "command": "pwsh -NoProfile -File \"${CLAUDE_PLUGIN_ROOT}/adapters/claude/frugal-gate.ps1\"",
      "shell": "powershell"
    }]}]
  }
}
```

## Настройка

| Переменная | По умолчанию | Что делает |
|---|---|---|
| `CONTINUUM_THRESHOLD` | `80` | Порог основного окна (%). |
| `CONTINUUM_TIERS` | `80 90 95 99` | Уровни основного окна. Каждый — один раз. |
| `CONTINUUM_THRESHOLD_7D` | `70` | Порог недельного окна. |
| `CONTINUUM_TIERS_7D` | `70 85 95` | Уровни недельного окна. |
| `CONTINUUM_PROVIDER` | `anthropic` | Провайдер(ы), через запятую. |
| `CONTINUUM_AGENT` | `claude` | Агент: выбирает пресет `resume` и формулировку `continuum check` (там без переменной — `generic`). |
| `CONTINUUM_RESUME_CMD` | пресет агента | Команда агента для `resume`. `{prompt}` = задача. Важнее пресета. |
| `CONTINUUM_DRY_RUN` | — | `resume` печатает вместо планирования. |
| `CONTINUUM_OFF` | — | Отключить предупреждение (`continuum check` и хуки). |
| `CONTINUUM_FRUGAL` | — | `1` = экономный режим: блокирует Agent. |
| `CONTINUUM_CACHE_MIN` | `10` | Время кэша (минуты). `0` отключает. |
| `CONTINUUM_STATE_DIR` | `~/.local/state/continuum` | Где лежат кэш, флаги, логи и конфиг. Если задан — миграция из `~/.claude` не выполняется. |
| `CONTINUUM_ROOT` | каталог установки | Где лежит код, если скрипт не может определить это сам. |
| `CONTINUUM_SPEND_CAP` | `100` | Месячный бюджет ($) для провайдера `spend`. Должно быть положительным числом. |
| `ANTHROPIC_ADMIN_KEY` | — | Admin API ключ для провайдера `spend`. |
| `CLAUDE_CODE_OAUTH_TOKEN` | — | OAuth-токен для провайдера `anthropic`. Запасной вариант, когда в Keychain / `~/.claude/.credentials.json` ничего usable нет. |

## Troubleshooting

**Ничего на 80%.** Хук срабатывает только на `Stop`. Запусти `sh tests/run.sh`. Проходит → плагин не загружен, проверь `/plugin`.

**`usage endpoint unavailable`.** Оффлайн, рейт-лимит (подожди 10 мин), или токен истёк. Перелогинься в Claude Code.

**`no OAuth token found`.** Не залогинен или credentials не там. Экспортируй `CLAUDE_CODE_OAUTH_TOKEN`.

**`continuum resume` не сработал.** Проверь `~/.local/state/continuum/continuum-resume.log`. macOS: `launchctl list | grep continuum`. Linux: `systemctl --user list-timers | grep continuum`.

**Предупреждение есть, Claude игнорирует.** Понизь `CONTINUUM_THRESHOLD`.

## Участие

```
sh tests/run.sh          # 114 тестов, mock-провайдер, без сети
pwsh tests/run.ps1       # тот же набор для PowerShell
```

Что помогло бы: провайдер для другого бюджета (OpenAI, Gemini — см. [docs/writing-a-provider.md](docs/writing-a-provider.md)) и адаптер для другого агента ([docs/harnesses.md](docs/harnesses.md)).

## Удаление

```
/plugin uninstall continuum
rm -f /usr/local/bin/continuum
rm -rf ~/.local/state/continuum ~/.continuum
rm -f ~/.claude/.continuum-* ~/.claude/continuum-resume.log   # остатки от версий до v0.6
```

Или: `continuum cleanup` удалит только устаревшие файлы (>24ч).

## Лицензия

MIT
