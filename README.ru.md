![continuum](assets/logo.png)

# continuum

> **🇷🇺 Русский** | **🇬🇧 [English](README.md)**

**Видишь лимит заранее. Решаешь, что делать с оставшимся. Продолжаешь с того же места.**

[![version: 0.5.0](https://img.shields.io/badge/version-0.5.0-brightgreen.svg)](https://github.com/TropinAlexey/continuum/releases) [![ci](https://github.com/TropinAlexey/continuum/actions/workflows/ci.yml/badge.svg)](https://github.com/TropinAlexey/continuum/actions/workflows/ci.yml) [![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

---

## What's new

**v0.5.0** — Поддержка BSD.

-   **FreeBSD / OpenBSD / NetBSD.** Все хуки и провайдеры работают из коробки (POSIX sh). `continuum resume` использует `daemon(8)` на FreeBSD для чистого detach; на остальных BSD — `nohup` fallback.

v0.4.0 — Resume не даёт машине заснуть.

-   **Автоматический wakelock.** `continuum resume` теперь сам предотвращает засыпание системы на время ожидания и выполнения задачи. macOS — `caffeinate`, Linux — `systemd-inhibit`, Windows — `SetThreadExecutionState`. Wakelock освобождается автоматически после завершения задачи. Больше не нужно вручную запускать `caffeinate`.
-   **Статуслайн.** Новый хук `hooks/statusline.sh` показывает процент использования лимита прямо в статусной строке Claude Code — с цветовой индикацией (зелёный / жёлтый / красный).

v0.3.1 — Resume доводит дело до конца.

-   **Автономный resume.** К каждому headless-промпту автоматически дописывается инструкция работать самостоятельно: не задавать вопросов, не ждать подтверждений, коммитить результат.
-   **Отчёт при старте сессии.** `SessionStart`-хук проверяет `continuum-resume.log` и показывает сводку завершённых resume за последние 24 часа.

---

## Коротко

У AI-агентов для кода есть лимиты использования на временное окно. Когда лимит кончается посреди задачи — сессия встаёт, и ты сам ждёшь сброса.

**continuum** следит за оставшимся бюджетом и предупреждает заранее, чтобы ты успел завершить работу чисто. Если решишь подождать — засыпает до сброса лимита и возобновляет сессию автоматически. Без присмотра.

## Объясни как инженеру

Четыре детали, склеенные одним механизмом Claude Code. Ничего не крутится в фоне.

1.  **Скрипт-провайдер** (`providers/anthropic.sh`) делает `curl` к эндпоинту использования Anthropic — токен из `$CLAUDE_CODE_OAUTH_TOKEN`, macOS Keychain, или `~/.claude/.credentials.json` — и печатает строку на каждое окно: `5h 86.5 1783000000` (имя, процент, reset как Unix epoch). Эти три колонки — весь контракт провайдера. Подставь скрипт, который отдаёт расход по API или токенный лимит — continuum не заметит разницы.
    
2.  **`Stop`-хук** (`hooks/continuum-check.sh`) запускается после каждого хода. Вызывает провайдера через 10-минутный кэш (позитивный и негативный — неудачный вызов тоже кэшируется, чтобы не долбить лимитированный эндпоинт каждый ход), сравнивает утилизацию с тирами `CONTINUUM_TIERS` (80/90/95/99 по умолчанию) и — вот весь трюк — печатает `{"decision":"block","reason":"..."}` на stdout. Это механизм Claude Code для запрета молчаливого завершения хода; `reason` подаётся модели как новый ввод. `stop_hook_active` проверяется первым (иначе бесконечный цикл), а файл-флаг по сессии означает что каждый тир срабатывает ровно один раз.
    
3.  **`PreToolUse`-хук** (`hooks/frugal-gate.sh`) — в экономном режиме (`CONTINUUM_FRUGAL=1`) блокирует вызовы `Agent`. Не просьба — запрет на уровне хука.
    
4.  **Скилл** (`skills/session-budget`) — то, что injected `reason` просит Claude запустить. Чистый prompt engineering: честно описать ситуацию, потом `AskUserQuestion` с вариантами. Никогда не решает за тебя.
    
5.  **`continuum resume`** — планирует `claude --continue -p "$PROMPT"` на после сброса. По умолчанию через `launchd` (macOS), `systemd-run` (Linux) или `daemon(8)` (FreeBSD). Если ни один не доступен — `nohup sleep` (переживает закрытие терминала, не ребут). Лог (`~/.claude/continuum-resume.log`) помечает `### resumed in DIR` / `### end (exit N)` вокруг запуска. По завершению — десктопное уведомление.
    

Ничего не трогает аккаунт, не тратит запрос без спроса, ничего нельзя не прочитать в нескольких сотнях строк POSIX `sh`.

## Установка в одну строку

Скопируй строку для своей ОС, вставь в терминал, нажми Enter.

**Mac или Linux**

```sh
curl -fsSL https://raw.githubusercontent.com/TropinAlexey/continuum/main/install.sh | sh
```

**Windows** (PowerShell)

```powershell
irm https://raw.githubusercontent.com/TropinAlexey/continuum/main/install.ps1 | iex
```

Затем набери `continuum status` чтобы увидеть сколько батарейки осталось.

> **Честное предупреждение:** эта команда скачивает скрипт из интернета и запускает. Если хочешь сначала посмотреть — правильный инстинкт — открой [install.sh](install.sh) / [install.ps1](install.ps1), прочитай (он короткий) и запусти руками.

---

## Что делает continuum

Даёт то, чего на экране лимита никогда не было: **предупреждение и выбор.**

Когда окно использования заполняется, Claude не молча завершает ход и оставляет тебя гадать. Он останавливается, говорит где мы и спрашивает:

```
Окно заполнено на 86%, сбрасывается в 21:40. Что делаем?

  > Закончить и свернуться       довести до рабочего состояния, прогнать тесты, показать diff
    Доделать текущий набор задач  завершить запланированный пакет, потом стоп — ничего нового
    Сохранить и продолжить        коммит, потом авто-resume после сброса
    Экономный режим               без субагентов, без больших файлов, короткие ответы
    Только дешёвые задачи         доки и коммит-сообщения, тяжёлый анализ отложить
    Продолжать как есть           проигнорировать предупреждение
```

Спрашивает на языке, на котором вы работаете. И не достаёт: предупреждение ступенчатое — **80% → 90% → 95% → 99%**, срабатывает один раз на каждом уровне. Недельное окно отслеживается отдельно — **70% → 85% → 95%**.

Выбрал *«сохранить и продолжить»* — commitит работу, планирует `claude --continue` на 21:41, отдаёт PID. Закрываешь ноутбук. В 21:41, без тебя, сессия продолжает с того же места. По завершению — десктопное уведомление.

### Экономный режим

Выбрал *«Экономный режим»* — устанавливается `CONTINUUM_FRUGAL=1`, и PreToolUse-хук **принудительно блокирует** вызовы субагентов (`Agent`). Это не просьба — это запрет на уровне хука.

## Два способа установки

**Однострочник** даёт команду `continuum` в любом терминале. Работает с любым AI-агентом.

**Плагин Claude Code** добавляет *автоматическое* предупреждение — часть где Claude сам останавливается на пороге и спрашивает что делать:

```
/plugin marketplace add TropinAlexey/continuum
/plugin install continuum
```

Хочешь оба? Ставь оба — однострочник для команды, плагин для автоматики. Не конфликтуют.

## Использование

```sh
continuum status      # 5 hours   86.5%   resets at 21:40
                      # 7 days    41.0%   resets at 02:00
continuum reset       # 21:41   (reset +90s, готово для планирования)
continuum estimate    # At this pace, ~2h 15m left before 100%
continuum providers   # anthropic, mock, spend
continuum watch       # поллинг в отдельной панели; звонок на пороге
continuum history     # последние 20 снапшотов использования
continuum cleanup     # удалить устаревшие файлы флагов/кэша (>24ч)

continuum resume "$(continuum reset)" "$PWD" "доделать тесты DocumentService"
```

Не используешь Claude Code? `continuum watch` не требует хуков и плагина — работает в любом терминале. `continuum resume` запускает любого агента:

```sh
CONTINUUM_RESUME_CMD='codex exec "{prompt}"'    continuum resume 21:41 "$PWD" "finish the tests"
CONTINUUM_RESUME_CMD='opencode run "{prompt}"'  continuum resume 21:41 "$PWD" "finish the tests"
```

См. **[docs/harnesses.md](docs/harnesses.md)** — что проверено, что вероятно.

## Прочитай перед установкой

**Используется недокументированный эндпоинт с OAuth-токеном.** `https://api.anthropic.com/api/oauth/usage` — то что вызывает `/usage`. Это не публичный API и может измениться без предупреждения. Провайдер `anthropic` ищет токен в `$CLAUDE_CODE_OAUTH_TOKEN`, потом в macOS Keychain, потом в `~/.claude/.credentials.json`. Токен уходит в один заголовок `curl`, на один хост. Несколько сотен строк шелла — читай перед тем как доверять.

**`continuum resume` запускает Claude без присмотра, с `--permission-mode acceptEdits`.** Спит до сброса, потом запускает `claude --continue -p "<prompt>"` в проекте. Правит код без наблюдателя. Делай промпт узким. Не направляй на то, что не дал бы мержить незнакомцу.

## Resume переживает перезагрузку

`continuum resume` автоматически выбирает лучший планировщик ОС:

ОС

Планировщик

Переживает ребут

Wakelock

macOS

`launchd` (one-shot plist)

да

`caffeinate -i`

Linux

`systemd-run --user` (transient timer)

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

`caffeinate` / `systemd-inhibit`

**Wakelock** предотвращает засыпание системы автоматически — на время ожидания до сброса и на время выполнения задачи. Освобождается после завершения, при отмене (`kill PID`), или при `continuum cleanup`. Не нужно вручную запускать `caffeinate`.

По завершению resume — **десктопное уведомление** (`osascript` на Mac, `notify-send` на Linux). Лог (`~/.claude/continuum-resume.log`) помечает `### resumed in DIR` / `### end (exit N)` — общий для всех проектов, `grep` по директории чтобы найти свой.

## Провайдеры

continuum не знает что такое Anthropic. Он спрашивает **провайдера** — «сколько использовано, когда сброс» — и всё остальное провайдер-агностично.

### Встроенные провайдеры

Провайдер

Что измеряет

Нужно

`anthropic`

Подписочные окна (5ч/7д)

OAuth-токен Claude Code

`spend`

Месячный расход по API-ключу

`ANTHROPIC_ADMIN_KEY`, `CONTINUUM_SPEND_CAP` ($ бюджет, по умолчанию 100)

`mock`

Фейковые числа для тестов

ничего

### Свой провайдер

Провайдер — скрипт, который печатает:

```
5h 86.5 1783000000
7d 41.0 1783300000
```

Вот и весь интерфейс. Написать свой — 10 минут: **[docs/writing-a-provider.md](docs/writing-a-provider.md)**. Положи в `~/.claude/providers/` и выбери через `CONTINUUM_PROVIDER=yours`.

### Несколько провайдеров одновременно

```sh
CONTINUUM_PROVIDER=anthropic,spend continuum status
```

Запускает оба, берёт самую высокую утилизацию как основную линию. Ловит ситуацию «5-часовое окно в порядке, но $40 за сегодня сожжено».

## Все ОС

Shell

Статус

macOS

`sh`

работает из коробки

Linux

`sh`

работает из коробки

FreeBSD / OpenBSD / NetBSD

`sh`

работает из коробки

Windows + Git Bash

`sh`

работает из коробки

Windows без Git Bash

PowerShell

`.ps1`, подключить ниже

Claude Code запускает хуки через Git Bash на Windows, откатывается на PowerShell если Git Bash нет. Две реализации, `.sh` и `.ps1`, проверяются одним тест-набором на всех ОС в CI. Без python, без node, без `jq` — POSIX `sh` + `curl`, или PowerShell 5.1+.

Без Git Bash — переопредели хуки в `settings.json`:

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

## Статуслайн

Показывает текущий процент использования прямо в статусной строке Claude Code, с цветовой индикацией: **зелёный** (<80%), **жёлтый** (80–94%), **красный** (≥95%). Обновляется каждые ~30 секунд через фоновое обновление кеша.

Добавь в `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "sh "$HOME/.claude/hooks/statusline.sh""
  }
}
```

При установке плагина скрипт копируется автоматически. При установке через однострочник скрипт уже лежит в `~/.claude/hooks/statusline.sh`.

## Настройка

Переменная

По умолчанию

Что делает

`CONTINUUM_THRESHOLD`

`80`

Порог основного окна (%). Тиры ниже него игнорируются.

`CONTINUUM_TIERS`

`80 90 95 99`

Уровни основного окна. Каждый срабатывает один раз.

`CONTINUUM_THRESHOLD_7D`

`70`

Порог недельного окна (%).

`CONTINUUM_TIERS_7D`

`70 85 95`

Уровни недельного окна.

`CONTINUUM_PROVIDER`

`anthropic`

Какого провайдера спрашивать. Через запятую — несколько.

`CONTINUUM_RESUME_CMD`

`claude --continue -p "{prompt}" …`

Какого агента будит `resume`. `{prompt}` — задача.

`CONTINUUM_DRY_RUN`

не задан

`resume` печатает команду вместо планирования.

`CONTINUUM_OFF`

не задан

Отключить Stop-хук.

`CONTINUUM_FRUGAL`

не задан

`1` — экономный режим: PreToolUse-хук блокирует Agent.

`CONTINUUM_CACHE_MIN`

`10`

Минуты кэширования ответа провайдера. `0` отключает кэш.

`CONTINUUM_SPEND_CAP`

`100`

Месячный бюджет в $ для провайдера `spend`.

`ANTHROPIC_ADMIN_KEY`

—

Admin API ключ для провайдера `spend`.

## Как работает

Claude Code вызывает `Stop`-хук каждый раз когда Claude завершает ход. Хук, который печатает `{"decision":"block","reason":"..."}` отправляет `reason` обратно Claude вместо того чтобы дать ходу закончиться. Вот и весь трюк. Наш reason несёт числа и говорит Claude запустить скилл `session-budget`.

Всё остальное — защита от граничных случаев вокруг этой идеи:

-   **Эндпоинт жёстко лимитирован**, а хук запускается после *каждого* хода. Ответы кэшируются на 10 минут, ошибка ставит маркер на ещё 10 — негативный кэш.
-   **`stop_hook_active` проверяется первым.** Claude Code ставит его при повторном запуске хука. Без этой проверки — бесконечный цикл.
-   **Флаг по сессии** — каждый уровень срабатывает один раз, не после каждого хода.
-   **Каждый путь ошибки выходит с 0 и молча.** Stop-хук который ошибается или болтает без повода — хуже чем никакого хука.

## Troubleshooting

**Ничего не происходит на 80%.** Хук срабатывает только на `Stop`. Проверь: `sh tests/run.sh`. Если проходит — плагин не загружен, проверь `/plugin`.

**`usage endpoint unavailable`.** Оффлайн, рейт-лимит (подожди 10 минут — негативный кэш работает), или токен истёк. Перелогинься в Claude Code.

**`no OAuth token found`.** Не залогинен, или credentials лежат не там. Экспортируй `CLAUDE_CODE_OAUTH_TOKEN`.

**`continuum resume` не сработал.** Проверь `~/.claude/continuum-resume.log` — ищи маркеры `### resumed in DIR` / `### end (exit N)`. Лог общий для всех проектов, `grep` по директории. На macOS — `launchctl list | grep continuum`. На Linux — `systemctl --user list-timers | grep continuum`. На FreeBSD — `ps aux | grep continuum`. Десктопное уведомление тоже срабатывает по завершению; если ни `osascript` ни `notify-send` не доступны — только лог.

**Предупреждение есть, Claude игнорирует.** Reason просит Claude запустить скилл; модель может решить иначе. Понизь `CONTINUUM_THRESHOLD`.

## Участие

```
sh tests/run.sh          # 55 тестов, mock-провайдер, без сети
pwsh tests/run.ps1       # тот же набор для PowerShell
```

CI запускает оба на Linux, macOS и Windows. Что реально помогло бы:

-   Провайдер для другого бюджета: OpenAI spend, Gemini quota. См. **[docs/writing-a-provider.md](docs/writing-a-provider.md)**.
-   Подтверждение, работает ли блокирующий `Stop`-хук в Codex CLI. [docs/harnesses.md](docs/harnesses.md) честно говорит что не знаем.

Без зависимостей. Каждый путь ошибки — молча.

## Удаление

```
/plugin uninstall continuum
rm -f /usr/local/bin/continuum
rm -f ~/.claude/.continuum-cache-* ~/.claude/.continuum-warned-* ~/.claude/.continuum-warned7d-* ~/.claude/.continuum-wakelock-* ~/.claude/.continuum-history.log
```

Или: `continuum cleanup` удалит только устаревшие файлы (>24ч).

## Лицензия

MIT