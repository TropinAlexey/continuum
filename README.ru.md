<p align="center">
  <img src="assets/logo.png" width="200" alt="continuum">
</p>

<h1 align="center">continuum</h1>

<p align="center">
  <b><a href="README.md">🇬🇧 English</a></b> | <b>🇷🇺 Русский</b>
</p>

<p align="center">
  <b>Видишь лимит заранее. Решаешь, что делать. Продолжаешь автоматически после сброса.</b>
</p>

<p align="center">
  <a href="https://github.com/TropinAlexey/continuum/releases"><img src="https://img.shields.io/badge/version-0.7.3-brightgreen.svg" alt="version: 0.7.0"></a>
  <a href="https://github.com/TropinAlexey/continuum/actions/workflows/ci.yml"><img src="https://github.com/TropinAlexey/continuum/actions/workflows/ci.yml/badge.svg" alt="ci"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="license: MIT"></a>
</p>

---

У AI-агентов есть лимит использования на временное окно, например 5 часов и неделя. Если лимит кончается посреди задачи, сессия останавливается и приходится ждать сброса. **continuum** следит за бюджетом, предупреждает до исчерпания и спрашивает, что делать с остатком. Если захочешь, он дождётся сброса и сам продолжит работу.

- **Предупреждения на 80 / 90 / 95 / 99 %:** агент останавливается и спрашивает тебя, что делать. Сам он не решает.
- **Авто-продолжение:** планирует запуск агента сразу после сброса, не даёт машине заснуть и уведомляет, когда закончит.
- **Статус-бар:** текущее использование обоих окон — в агентах, у которых есть статусная строка.

Ядро не знает, какой агент его вызвал и откуда берутся цифры: агенты подключаются через тонкие [адаптеры](#агенты), бюджеты — через [провайдеры](#провайдеры). POSIX `sh` и `curl`, без зависимостей. macOS, Linux, BSD, Windows.

## Установка

**1. CLI** (команда `continuum`, работает с любым агентом):

```sh
# Mac / Linux / BSD
curl -fsSL https://raw.githubusercontent.com/TropinAlexey/continuum/main/install.sh | sh

# Windows (PowerShell)
irm https://raw.githubusercontent.com/TropinAlexey/continuum/main/install.ps1 | iex
```

Скрипты установки короткие, их можно прочитать заранее: [install.sh](install.sh) / [install.ps1](install.ps1).

**2. Адаптер твоего агента** — для предупреждений внутри сессии. Какие есть — в разделе [Агенты](#агенты). Агент без адаптера может вызывать `continuum check` из своего хука, или можно держать `continuum watch` в отдельной панели.

## Что он трогает

Что ядро читает, отправляет, пишет и запускает. Каждый адаптер добавляет свой список — в своём разделе ниже.

- **Сеть.** В сеть ходит только провайдер. Провайдер по умолчанию, `anthropic`, делает один `GET https://api.anthropic.com/api/oauth/usage` с OAuth-токеном в заголовке `Authorization`. Это **недокументированный эндпоинт**, не публичный API, и он может измениться. Ответ кэшируется на 10 минут. Необязательный провайдер `spend` обращается к `https://api.anthropic.com/v1/billing/usage` с `ANTHROPIC_ADMIN_KEY`. Больше ничего с машины не уходит.
- **Учётные данные.** Провайдер `anthropic` ищет токен в таком порядке: `$CLAUDE_CODE_OAUTH_TOKEN`, запись `Claude Code-credentials` в Keychain macOS, затем `~/.claude/.credentials.json`. Он уходит только на `api.anthropic.com` и нигде не сохраняется.
- **Файлы.** Кэш, флаги, логи и конфиг лежат в `~/.local/state/continuum` (см. [Настройка](#настройка)). CLI-инсталлятор кладёт код в `~/.continuum`, а символическую ссылку на него — в каталог из `PATH`.
- **Уведомления.** Уведомление на рабочий стол (`osascript` / `notify-send` или твой `CONTINUUM_NOTIFY_CMD`), когда запуск resume закончился и когда лимит кончился посреди хода. Текст уходит в `osascript` аргументами, а не как скрипт.
- **Запуск без присмотра.** `continuum resume` запускает агента, когда никто не смотрит, по пресету агента или по `CONTINUUM_RESUME_CMD`; внутри треда bb вместо этого отправляет задачу в тот же тред через `bb thread tell`. Запуск происходит только по твоему выбору: вариант «сохранить и продолжить», ручной вызов команды или заранее заданный `CONTINUUM_RESUME_ON_LIMIT=1`, который планирует resume, когда лимит кончился посреди хода. Ставь узкую задачу и не направляй его на то, что не дал бы мержить незнакомцу.

## Что происходит

Когда использование пересекает порог, агент останавливается и спрашивает:

> *Окно заполнено на 86%, сбрасывается в 21:40. Что делаем?*

Варианты: свернуться, доделать текущий пакет, сохранить и продолжить после сброса, экономный режим (без субагентов), только дешёвые задачи или проигнорировать. Агент спрашивает на твоём языке.

Предупреждения ступенчатые, **80% → 90% → 95% → 99%**, каждая ступень срабатывает один раз. Недельное окно отслеживается отдельно (**70% → 85% → 95%**), и его предупреждение называет день и время сброса («resets Fri 18:28»). Если использование опустилось ниже ступени, потому что окно сменилось или лимит докупили, ступень взводится заново и сработает снова на росте.

Если агент позволяет адаптеру заглядывать после каждого вызова инструмента, проверка идёт и посреди хода, поэтому длинный ход со сборками или параллельными субагентами не пересечёт порог незаметно. Тогда агент доделывает текущий шаг, оставляет работу в целостном состоянии и спрашивает.

Выбираешь «сохранить и продолжить»: агент коммитит работу, планирует свой запуск на после сброса и показывает PID. Ноутбук можно закрыть, сессия продолжится без тебя.

## Использование

```sh
continuum status      # 5 hours   86.5%   resets at 21:40
                      # 7 days    41.0%   resets at 02:00
continuum reset       # 21:41   (сброс +90с, готово для планировщика)
continuum estimate    # при таком темпе ещё ~2ч 15м
continuum watch       # опрос в отдельной панели; звонок на пороге
continuum history     # последние 20 снимков, сделанных `continuum status`
continuum cleanup     # удалить устаревшие файлы флагов и кэша (>24ч)
continuum providers   # anthropic, mock, spend
continuum check       # печатает предупреждение при пересечении новой ступени, иначе ничего
continuum statusline  # показать конфиг статус-бара

continuum resume "$(continuum reset)" "$PWD" "доделать тесты DocumentService"
```

Давай `resume` конкретную задачу, а не общее «продолжи»: продолжённая сессия начинает только с этого промпта и репозитория.

## Агенты

Ядро (`bin/`, `lib/`, `providers/`) никогда не спрашивает, какой агент его вызвал. У каждого агента свой тонкий адаптер в `adapters/<агент>/`, который переводит его протокол хуков в `continuum check` и обратно.

| Агент | Предупреждение в сессии | Пресет resume | Статус |
|---|---|---|---|
| **Claude Code** | [адаптер](#claude-code), плагин | `CONTINUUM_AGENT=claude` (по умолчанию) | Поддерживается, проверен вживую, тестируется в CI |
| **Codex CLI** | [адаптер](#codex-cli), `hooks.json` | `CONTINUUM_AGENT=codex` | Новый: тесты в CI, вживую ещё не запускался |
| **Gemini CLI** | [адаптер](#gemini-cli), `settings.json` | `CONTINUUM_AGENT=gemini` | Новый: тесты в CI, вживую ещё не запускался |
| **Cursor** | [адаптер](#cursor), `hooks.json` | `CONTINUUM_AGENT=cursor` | Новый: тесты в CI, вживую ещё не запускался |
| **opencode** | [адаптер](#opencode), JS-плагин | `CONTINUUM_AGENT=opencode` | Новый: тесты в CI, вживую ещё не запускался |
| **Junie** (JetBrains: RustRover, IDEA, …) | плагин Claude Code, установленный как расширение Junie ([Junie](#junie-jetbrains)) | `CONTINUUM_AGENT=junie` | Новый: проверен вживую (CLI); чат в IDE хуки пока не вызывает |
| **bb** (приложение) | адаптер агента, запущенного в треде ([bb](#bb)) | автоматически: `bb thread tell` в тот же тред | Новый: тесты в CI, вживую ещё не запускался |
| Любой другой | `continuum check` из хука или `continuum watch` в отдельной панели | задай `CONTINUUM_RESUME_CMD` | Работает уже сейчас |

```sh
CONTINUUM_AGENT=codex continuum resume 21:41 "$PWD" "finish the tests"
CONTINUUM_RESUME_CMD='myagent run "{prompt}"' continuum resume 21:41 "$PWD" "finish the tests"
```

«Тесты в CI» — ответы каждого адаптера сверяются с документированным протоколом хуков агента. «Проверен вживую» — настоящая сессия этого агента получила предупреждение. Если запустишь какой-то вживую, расскажи, как прошло (issue или PR в [docs/harnesses.md](docs/harnesses.md)).

Агент и провайдер независимы: сессия Codex может следить за окном Anthropic, и наоборот. Что проверено и как написать адаптер — в [docs/harnesses.md](docs/harnesses.md).

## Как работает

Большинство агентов умеют запускать хук в конце хода, а некоторые — после каждого вызова инструмента. Если ответ хука может вернуть модели текст вместо завершения хода, туда и кладётся предупреждение. Вот и весь трюк.

```
событие агента ──► adapters/<агент>/ ──► continuum check ──► провайдер
                   (протокол агента)     (ступени, кэш,      (usage, сброс)
                                          флаги, текст)
```

1. **Провайдер** (`providers/anthropic.sh`): `curl` к эндпоинту, печатает `5h 86.5 1783000000` (окно, процент, epoch сброса). Эти три колонки — весь контракт провайдера.
2. **`continuum check`**: агент-нейтральное ядро предупреждения. Вызывает провайдера через 10-минутный кэш (кэшируются и успехи, и сбои), сравнивает результат со ступенями и печатает текст предупреждения или ничего. Флаг на сессию гарантирует, что каждая ступень срабатывает один раз, каким бы хуком её ни поймали первой.
3. **Адаптер** (`adapters/<агент>/`): превращает события агента в `continuum check --session … --agent <имя>`, а текст — в то, чего ждёт протокол хуков агента.
4. **Скилл** (`skills/session-budget`): то, что предупреждение просит агента запустить. Показывает ситуацию и спрашивает тебя инструментом вопросов агента, если он есть. Никогда не решает за тебя.
5. **`continuum resume`**: планирует headless-команду агента на после сброса. Выбирает лучший планировщик ОС, не даёт машине заснуть и уведомляет, когда запуск закончится.

## Resume

`continuum resume` сам выбирает планировщик и не даёт системе заснуть:

| ОС | Планировщик | Переживает перезагрузку | Wakelock |
|---|---|---|---|
| macOS | `launchd` | да | `caffeinate -i` |
| Linux | `systemd-run --user` | да | `systemd-inhibit` |
| FreeBSD | `daemon(8)` | только logout | — |
| Windows | detached process | нет | `SetThreadExecutionState` |
| Fallback | `nohup sleep` | нет | лучший доступный |

Лог — `continuum-resume.log` в каталоге состояния, с маркерами `### resumed in DIR` и `### end (exit N)`. Когда запуск заканчивается, приходит уведомление на рабочий стол (`osascript` / `notify-send`).

Внутри треда [bb](#bb) возобновление — не отдельная headless-сессия: задача уходит обратно в тот же тред через `bb thread tell`.

## Провайдеры

continuum всё равно, откуда берутся цифры. Он спрашивает только, сколько окна использовано и когда сброс.

Провайдер — это скрипт, который печатает `5h 86.5 1783000000`, и это весь интерфейс. Свой можно написать за 10 минут: [docs/writing-a-provider.md](docs/writing-a-provider.md).

**Несколько провайдеров:** `CONTINUUM_PROVIDER=anthropic,spend` запускает оба и берёт наибольшее использование. Пробелы вокруг запятой допустимы.

## Платформы

macOS, Linux, FreeBSD/OpenBSD/NetBSD, Windows (Git Bash или PowerShell). POSIX `sh` и `curl`, без зависимостей. CI гоняет и `.sh`, и `.ps1` сюиты на каждой платформе.

## Настройка

| Переменная | По умолчанию | Что делает |
|---|---|---|
| `CONTINUUM_THRESHOLD` | `80` | Порог основного окна (%). |
| `CONTINUUM_TIERS` | `80 90 95 99` | Ступени основного окна. Каждая срабатывает один раз. |
| `CONTINUUM_THRESHOLD_7D` | `70` | Порог недельного окна. |
| `CONTINUUM_TIERS_7D` | `70 85 95` | Ступени недельного окна. |
| `CONTINUUM_PROVIDER` | `anthropic` | Провайдер(ы), через запятую. |
| `CONTINUUM_AGENT` | `claude` | Агент: `claude`, `codex`, `gemini`, `cursor` или `opencode`. Выбирает пресет `resume` и формулировку `continuum check` (там без переменной — `generic`). |
| `CONTINUUM_RESUME_CMD` | пресет агента | Команда агента для `resume`. `{prompt}` — задача. Важнее пресета. |
| `CONTINUUM_RESUME_ON_LIMIT` | выкл. | `1`: когда лимит кончился посреди хода (`StopFailure`), запланировать resume на сброс по пресету агента. Только если сброс в ближайшие 24 ч; один на каталог за окно. Согласие заранее. |
| `CONTINUUM_NOTIFY_CMD` | `osascript` / `notify-send` | Заменить уведомлялку; получает заголовок и текст двумя аргументами. |
| `CONTINUUM_DRY_RUN` | — | `resume` печатает план вместо планирования. |
| `CONTINUUM_OFF` | — | Отключает предупреждение (`continuum check` и все хуки адаптеров). |
| `CONTINUUM_FRUGAL` | — | `1` = экономный режим: адаптеры, которые умеют, блокируют вызовы субагентов. |
| `CONTINUUM_CACHE_MIN` | `10` | Время жизни кэша в минутах. `0` отключает. |
| `CONTINUUM_STATE_DIR` | `~/.local/state/continuum` | Где лежат кэш, флаги, логи и конфиг (иначе `$XDG_STATE_HOME/continuum`). Если задан, разовая миграция из `~/.claude` не выполняется. |
| `CONTINUUM_ROOT` | каталог установки | Где лежит код, если скрипт не может определить это сам. |
| `CONTINUUM_SPEND_CAP` | `100` | Месячный бюджет ($) для провайдера `spend`. Положительное число. |
| `ANTHROPIC_ADMIN_KEY` | — | Admin API ключ для провайдера `spend`. |
| `CLAUDE_CODE_OAUTH_TOKEN` | — | OAuth-токен для провайдера `anthropic`. Проверяется раньше Keychain и `~/.claude/.credentials.json`. |

## Если что-то не так

**Нет предупреждения на 80%.** Запусти `sh tests/run.sh`. Если он проходит, с кодом всё в порядке, и дело в том, как подключён адаптер агента; см. его раздел ниже.

**`usage endpoint unavailable`.** Нет сети, сработал рейт-лимит (сбои тоже кэшируются, подожди 10 минут) или истёк токен. Перелогинься в агенте, которому принадлежит токен.

**`no OAuth token found`.** Ты не залогинен, или учётные данные лежат в неожиданном месте. Экспортируй `CLAUDE_CODE_OAUTH_TOKEN`.

**`continuum resume` не запустился.** Посмотри `~/.local/state/continuum/continuum-resume.log`. macOS: `launchctl list | grep continuum`. Linux: `systemctl --user list-timers | grep continuum`.

**Предупреждение приходит, но агент его игнорирует.** Понизь `CONTINUUM_THRESHOLD`, чтобы оно приходило раньше.

## Claude Code

Адаптер лежит в [`adapters/claude/`](adapters/claude/README.md) и поставляется как плагин Claude Code.

**Установка:**

```
/plugin install continuum --marketplace TropinAlexey/continuum
```

В Claude Code старше 2.1.275 — в два шага: `/plugin marketplace add TropinAlexey/continuum`, затем `/plugin install continuum`. После установки перезапусти сессию: хуки подхватываются при старте. Плагин и CLI не конфликтуют.

**Что он добавляет:**

- **Хуки.** `Stop`: в конце хода предупреждение превращается в `{"decision":"block","reason":"..."}`, и Claude вместо остановки продолжает и спрашивает тебя. `PostToolUse`: после каждого вызова инструмента — то же предупреждение через `additionalContext`, около 0,1 с на вызов, молчит внутри субагентов. `PreToolUse`: блокирует инструмент `Agent`, только в экономном режиме (`CONTINUUM_FRUGAL=1`). `StopFailure` (`rate_limit`): лимит кончился посреди хода, спросить уже нельзя — уведомление, строка в логе resume и заметка при следующем старте сессии, плюс запланированный resume, если задан `CONTINUUM_RESUME_ON_LIMIT=1`. `SessionStart`: отчёт о resume (и эта заметка) и обслуживание статус-бара.
- **Настройки.** При старте сессии, если в `~/.claude/settings.json` нет `statusLine`, плагин копирует свой скрипт статус-бара в `~/.claude/hooks/statusline.sh` и добавляет запись `statusLine`, указывающую на него. Дальше он держит эту копию в актуальном состоянии. Чужой или твой собственный статус-бар не трогается. CLI-инсталлятор делает то же самое.
- **Вопросы.** Предупреждение просит Claude использовать `AskUserQuestion`.
- **Пресет resume.** `claude --continue -p "<задача>" --permission-mode acceptEdits`.

**Статус-бар.** Показывает использование в статусной строке: **зелёный** ниже 80%, **жёлтый** 80–94%, **красный** от 95%. Обновляется примерно каждые 30 секунд. Устаревший кэш (старше 10 минут или записанный до сброса окна) обновляется до первой отрисовки, поэтому новая сессия сразу показывает актуальные цифры. Если провайдер недоступен, остаются старые цифры, а следующая попытка будет через 2 минуты.

```json
{
  "statusLine": {
    "type": "command",
    "command": "sh \"$HOME/.claude/hooks/statusline.sh\""
  }
}
```

Формат настраивается токенами `{d%}` (5-часовой %), `{w%}` (недельный %), `{dr}` (сброс 5-часового), `{wr}` (сброс недельного):

```sh
continuum statusline                    # показать текущий конфиг
continuum statusline format "{d%} d {dr} | {w%} w {wr}"
continuum statusline format-single "{d%} d {dr}"   # когда окно только одно
continuum statusline time "%H:%M"       # формат времени сброса
continuum statusline date "%d.%m"       # формат даты сброса (когда не сегодня)
continuum statusline today "today"      # слово для сегодняшнего сброса
continuum statusline reset              # вернуть настройки по умолчанию
```

**Windows без Git Bash.** Используй `adapters/claude/statusline.ps1` как команду `statusLine` и `continuum.ps1 statusline` для тех же настроек, а хуки переопредели в `settings.json`:

```json
{
  "hooks": {
    "Stop": [{ "hooks": [{
      "type": "command",
      "command": "pwsh -NoProfile -File \"${CLAUDE_PLUGIN_ROOT}/adapters/claude/stop.ps1\"",
      "shell": "powershell"
    }]}],
    "PostToolUse": [{ "hooks": [{
      "type": "command",
      "command": "pwsh -NoProfile -File \"${CLAUDE_PLUGIN_ROOT}/adapters/claude/tool-check.ps1\"",
      "shell": "powershell"
    }]}],
    "StopFailure": [{ "matcher": "rate_limit", "hooks": [{
      "type": "command",
      "command": "pwsh -NoProfile -File \"${CLAUDE_PLUGIN_ROOT}/adapters/claude/stop-failure.ps1\"",
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

**Нет предупреждения на 80%.** Проверь, что плагин включён: `/plugin` должен показывать `continuum`. Потом — что вместо него не подключена старая копия: в `settings.json` не должно быть `Stop`-хука на `token-budget-check.sh` (остаток с тех времён, когда плагин ещё не назывался continuum).

**Удаление:** `/plugin uninstall continuum`, затем `rm -f ~/.claude/hooks/statusline.sh` и убрать `"statusLine"` из `~/.claude/settings.json`.

## Codex CLI

Адаптер лежит в [`adapters/codex/`](adapters/codex/README.md): хук `Stop` (`decision: block` — Codex продолжает и спрашивает тебя) и хук `PostToolUse` (`additionalContext`, посреди хода). Сам он ничего в конфиге Codex не меняет: добавь оба хука в `~/.codex/hooks.json`, как показано в README адаптера, и одобри их в `/hooks`. Codex запускает хук только после одобрения, и заново после каждого обновления. Пресет resume: `codex exec resume --last -c sandbox_mode=workspace-write "<задача>"`.

## Gemini CLI

Адаптер лежит в [`adapters/gemini/`](adapters/gemini/README.md): хук `AfterAgent` (`decision: deny` — Gemini возвращает предупреждение как новый промпт) и хук `AfterTool` (`additionalContext`). Сам он ничего в конфиге Gemini не меняет: добавь оба хука в `~/.gemini/settings.json`, как показано в README адаптера. Пресет resume: `gemini --resume latest --approval-mode auto_edit -p "<задача>"`.

## Cursor

Адаптер лежит в [`adapters/cursor/`](adapters/cursor/README.md): хук `stop` (`followup_message` — уходит следующим сообщением пользователя) и хук `postToolUse` (`additional_context`). Сам он ничего в конфиге Cursor не меняет: добавь оба хука в `~/.cursor/hooks.json`, как показано в README адаптера. Пресет resume: `agent -p --continue "<задача>"`. Без `--force` headless-агент только предлагает изменения. Чтобы он менял файлы и запускал команды без присмотра, включи это сам: `CONTINUUM_RESUME_CMD='agent -p --force --continue "{prompt}"'` — с той же осторожностью, что и любой запуск без присмотра.

## opencode

Адаптер — плагин [`adapters/opencode/continuum.js`](adapters/opencode/README.md). На `session.idle` он отправляет предупреждение в сессию как промпт, после каждого вызова инструмента дописывает его к выводу инструмента. Ставится символической ссылкой в `~/.config/opencode/plugins/`, как показано в README адаптера. Он запускает только `continuum check`. Пресет resume: `opencode run --continue "<задача>"`.

## Junie (JetBrains)

Junie CLI ставит плагины Claude Code как расширения и запускает их хуки, поэтому continuum работает в нём как есть: в Junie `/extensions`, добавь маркетплейс `https://github.com/TropinAlexey/continuum`, установи `continuum`. Адаптер Claude Code узнаёт Junie по событиям (`project_path` без `transcript_path`): предупреждение просит Junie закончить итоговое сообщение вопросом (инструмента вопроса у неё нет), проверка внутри хода идёт на `PreToolUse` (`PostToolUse` у Junie нет), настройки Claude Code не трогаются. Пресет resume: `junie --skip-update-check --resume --task "<задача>"`. В IDE (RustRover, IntelliJ IDEA, Rider, …) агента для AI-чата выбираешь сам; Junie там идёт через ACP, а он хуки пока не вызывает, другие агенты чата ещё не проверены: используй Junie CLI или Claude Code в терминале IDE, либо `continuum watch`. Подробно — [`adapters/junie/`](adapters/junie/README.md).

## bb

bb — десктоп-приложение, которое запускает агентов в тредах, поэтому предупреждение приходит от адаптера самого агента: треды Claude Code подгружают плагины, включённые в `~/.claude/settings.json` (поставь плагин [Claude Code](#claude-code)), треды Codex читают `~/.codex/hooks.json` ([Codex CLI](#codex-cli)). bb передаёт агенту `BB_THREAD_ID`; если он задан, `continuum resume` отправляет задачу обратно в тот же тред через `bb thread tell <id> "<задача>"`, а не запускает отдельную headless-сессию (bb должен быть запущен в момент сброса; `CONTINUUM_RESUME_CMD` по-прежнему главнее). Подробно — [`adapters/bb/`](adapters/bb/README.md).

## Участие

```
sh tests/run.sh          # 197 тестов, mock-провайдер, без сети (проходит и под dash)
pwsh tests/run.ps1       # 160 тестов, та же сюита для PowerShell
```

Каждая правка `.sh` дублируется в `.ps1`, с тестами в обе сюиты. Пригодится помощь с провайдером для другого бюджета (OpenAI, Gemini: см. [docs/writing-a-provider.md](docs/writing-a-provider.md)) и с адаптером для другого агента ([docs/harnesses.md](docs/harnesses.md)).

## Удаление

```sh
rm -f "$(command -v continuum)"            # ссылка на CLI (~/.local/bin, /usr/local/bin или ~/bin)
rm -rf ~/.local/state/continuum ~/.continuum
rm -f ~/.claude/.continuum-* ~/.claude/continuum-resume.log   # остатки от версий до v0.6
```

Адаптер агента удаляется так, как сказано в его разделе. Удалить только устаревшие файлы (старше 24 часов) — `continuum cleanup`.

## Лицензия

MIT
