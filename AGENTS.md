# continuum — главный файл для всех агентов (AGENTS.md)

> Это source of truth для любого агента (Claude Code, Codex, opencode, Cursor).
> Утром на вопрос «что дальше делаем?» — прочитай разделы «Текущее состояние» и «Дальше»,
> затем `git log --oneline -5` и `.remember/now.md`. Детальная посуточная история — в `.remember/`.
> Обновляй этот файл на каждой важной вехе (релиз, merge, смена архитектуры).

## Что это

**continuum** — следит за лимитом usage-окна AI-агента, предупреждает до исчерпания и авто-продолжается после ресета.
Девиз: *See the limit coming. Decide what to do. Auto-resume after reset.*

- Репозиторий: `TropinAlexey/continuum` (локально `claude-token-budget`), ветка `main`, лицензия MIT.
- Платформы: macOS, Linux, FreeBSD/OpenBSD/NetBSD, Windows (Git Bash или PowerShell). Только POSIX `sh` + `curl`, без зависимостей.
- **Agent-agnostic** (с 2026-09-24): ядро (`bin/`, `lib/`, `providers/`) не знает, какой агент его вызвал; интеграции — тонкие адаптеры в `adapters/<агент>/`. Агент и провайдер — независимые оси.
- Артефакты: **CLI** (`bin/continuum` + `bin/continuum.ps1`), **адаптеры** (сейчас только `adapters/claude/`, он же Claude Code plugin через `hooks/hooks.json`) и скиллы.

## Как устроено

1. **Provider** (`providers/anthropic.sh`) — `curl` к usage-endpoint, печатает `5h 86.5 1783000000` (окно, %, epoch ресета). Весь контракт провайдера — эти 3 колонки. Свои провайдеры: `docs/writing-a-provider.md`.
2. **`continuum check [--session ID] [--agent NAME]`** — агент-нейтральное ядро предупреждения: 10-мин кэш, тиры, флаги, текст. Пусто = молчать, иначе одна строка текста; exit 0 всегда (кроме плохих аргументов). Тиры: `80→90→95→99` (основное окно), `70→85→95` (weekly). Каждый тир один раз, пере-вооружается при спаде usage. Формулировка «как спросить» по агенту — `cnt_ask_hint`.
3. **Адаптер Claude** (`adapters/claude/`): `stop.sh` (Stop-событие → `check` → blocking JSON), `frugal-gate.sh` (в `CONTINUUM_FRUGAL=1` блокирует `Agent`), `statusline.sh`, `setup-statusline.sh`, `resume-report.sh` (+ `.ps1`). `hooks/*.sh|ps1` — форвардеры для старых конфигов, удалить в v0.7.
4. **Skill** (`skills/session-budget/SKILL.md`) — что делать при предупреждении: показать ситуацию, спросить пользователя через AskUserQuestion (на его языке), никогда не решать за него. Опции: wrap up / finish batch / save+resume / frugal / cheap-only / ignore.
5. **`continuum resume`** — планирует headless-команду агента после ресета: `CONTINUUM_RESUME_CMD` → пресет `CONTINUUM_AGENT` (по умолчанию `claude`; пресеты других агентов появятся с их адаптерами) → ошибка. Планировщик по ОС: launchd / systemd-run / daemon(8) / detached process / nohup-fallback. Вейклок + нотификация.
6. **Состояние** — `CNT_STATE`: `$CONTINUUM_STATE_DIR` → `$XDG_STATE_HOME/continuum` → `~/.local/state/continuum` (одинаково в sh и ps1). НЕ `~/.continuum` — там код от инсталлятора (`CONTINUUM_HOME`). Разовая миграция из `~/.claude` (копирует conf/логи/провайдеры, не кэш; маркер `.migrated`). `$CNT_STATE/root` — указатель на код для скриптов без окружения (копия statusline в `~/.claude/hooks/`). Токен Claude (`~/.claude/.credentials.json`) ищет провайдер `anthropic`, не ядро.

Плюс: **statusline** (`hooks/statusline.sh`) — % в статус-баре Claude Code: зелёный <80%, жёлтый 80–94%, красный ≥95%. Формат настраивается (`continuum statusline format ...`).

## Карта репо

- `bin/continuum`, `bin/continuum.ps1` — CLI (status/reset/estimate/watch/history/cleanup/providers/statusline/resume).
- `adapters/claude/` — Claude Code адаптер (stop, frugal-gate, statusline, setup-statusline, resume-report + `.ps1`).
- `hooks/hooks.json` — манифест хуков плагина (указывает в `adapters/claude/`); `hooks/*.sh|ps1` — форвардеры совместимости.
- `lib/core.sh`, `lib/core.ps1` — общая логика (провайдеры, кэш, JSON-парсинг).
- `providers/` — `anthropic.sh`, `mock.sh`, `spend.sh`.
- `skills/session-budget/`, `skills/auto-resume/` — скиллы плагина.
- `tests/run.sh`, `tests/run.ps1` — единый сьют, mock-провайдер, без сети.
- `docs/harnesses.md` (агенты + «Writing an adapter»), `docs/writing-a-provider.md` — доки.
- `docs/superpowers/specs/2026-09-24-agent-neutral-core-design.md` — спека agent-agnostic (подпроект 1 из 5).
- `README.md` (EN) + `README.ru.md` (RU) — держать синхронно, шапка центрированная, лого `assets/logo.png` 120px.
- `.remember/` — автопамять Claude-плагина remember (now.md / today-*.md / recent.md / archive.md). Только для Claude; кросс-агентная правда — этот файл.

## Команды

```sh
sh tests/run.sh          # 114 тестов, mock, без сети (эталон; проходит и под dash)
pwsh tests/run.ps1       # 91 тест, та же сюита для PowerShell
continuum status         # 5h 86.5% resets at 21:40 + weekly строка
continuum reset          # HH:MM ресета (+90s, для планировщика)
continuum estimate       # сколько осталось at this pace
continuum watch          # опрос в отдельной панели, bell на пороге
continuum history        # последние 20 снапшотов
continuum check --session ID --agent claude  # ядро предупреждения для любого агента
continuum resume "$(continuum reset)" "$PWD" "конкретная задача"  # NEVER generic "continue"
```

## Текущее состояние (2026-09-24)

- `main` = `origin/main` (HEAD `e2e6085`) + **незакоммиченный подпроект 1 agent-agnostic** в рабочем дереве (коммит — только по просьбе пользователя).
- Подпроект 1 сделан: agent-нейтральное ядро (`continuum check`, `CNT_STATE` + миграция, root-указатель, пресеты resume) + `adapters/claude/`. **Тесты: sh 114/114 (и под dash), ps 91/91**, shellcheck чист, e2e-установка в изолированный HOME проверена.
- v0.5.0 зарелизен; v0.5.1 так и не выпущен — после этой работы логичнее сразу v0.6.0 (смена пути состояния).

## Прогресс последней недели

- 16.09: wakelock, README v0.5.0 En/Ru, statusline 30s-кэш, BSD, bump версии, лого/иконки — запушено.
- 17.09: rebase/push `14cf032`, README-рерайт + resume-no-commit, statusline race-fix (tmp+atomic mv) + `continuum statusline config`, 63/63 на тот момент.
- 18–20.09: code-review hardening, PS statusline + конфиг, 84/84, merge PR #1 (`e2e6085`). Детально — `.remember/today-2026-09-1*.md`, `recent.md`.
- 24.09: agent-agnostic, подпроект 1 (ядро + Claude-адаптер), 114/91 тестов, не закоммичено.

## Дальше (беклог, по приоритету)

1. **Закоммитить подпроект 1** (ветка `feat/agent-neutral-core`, PR) → релиз **v0.6.0**: бейдж в README ×2 + `plugin.json`, обе сюиты, тег.
2. **Адаптер Codex CLI** (подпроект 2) — своя спека по актуальной доке Codex: хуки, соблюдает ли `block`, пресет resume, строка в `cnt_ask_hint`.
3. **Адаптер opencode** (подпроект 3) — JS-плагин, зовущий `continuum check`.
4. **Адаптеры Cursor и Gemini CLI** (подпроект 4).
5. **`continuum install --agent <x>`** + доки (подпроект 5); заодно проверить marketplace-установку с нуля.
6. **Новый провайдер** — OpenAI или Gemini по `docs/writing-a-provider.md` (отдельная ось от агентов).
7. Мелочи: statusline по умолчанию печатает `86%%` (формат `{d%}%` дублирует `%`) — баг, был до agent-agnostic; `continuum cleanup` от `.DS_Store`-мусора?

## Feedback от агентов (обязательно)

- Папка `feedback/` — отзывы любого агента, который пользовался continuum. В git не коммитится (кроме `README.md`).
- После каждого meaningful использования оставь отзыв: `feedback/YYYY-MM-DD-<агент>-<тема>.md` по шаблону из `feedback/README.md`.
- В начале каждой рабочей сессии проверь новые файлы в `feedback/` (по mtime, которых ты ещё не видел) и учти их при планировании; годное переноси в раздел «Дальше».

## Утренний протокол («что дальше делаем?»)

1. Прочитай «Текущее состояние» и «Дальше» выше.
2. `git log --oneline -5 && git status -sb`, загляни в `.remember/now.md`, проверь новые файлы в `feedback/`.
3. Если `main` грязный или отстаёт — скажи об этом первым.
4. Предложи 1 следующий шаг из беклога + команду для старта. Без новых скоупов, пока не закроем выбранное.

## Конвенции (обязательно для всех агентов)

- Правки в файлы — сразу, без запроса подтверждений. Shell-команды — всегда одной строкой, без переносов.
- Поиск/чтение — встроенными Read/Grep/Glob; связи кода — через code-review-graph, если настроен.
- POSIX `sh`, без зависимостей; каждая правка `.sh` дублируется в `.ps1` (и наоборот) + тесты в обе сюиты.
- README.md и README.ru.md — всегда синхронны по смыслу.
- Коммиты — только по явной просьбе. Формат conventional commits. Никаких секретов в коде.
- Мелкие текстовые задачи (перефразировка, кейс-конверсия, тестовые данные) — через `ask_apfel` (on-device), не своей генерацией.
