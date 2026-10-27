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
- Артефакты: **CLI** (`bin/continuum` + `bin/continuum.ps1`), **адаптеры** (`adapters/claude/` — он же Claude Code plugin через `hooks/hooks.json`; `codex/`, `gemini/`, `cursor/` — command-хуки на общем `adapters/lib.sh|ps1`; `opencode/continuum.js` — JS-плагин) и скиллы.

## Как устроено

1. **Provider** (`providers/anthropic.sh`) — `curl` к usage-endpoint, печатает `5h 86.5 1783000000` (окно, %, epoch ресета). Весь контракт провайдера — эти 3 колонки. Свои провайдеры: `docs/writing-a-provider.md`.
2. **`continuum check [--session ID] [--agent NAME]`** — агент-нейтральное ядро предупреждения: 10-мин кэш, тиры, флаги, текст. Пусто = молчать, иначе одна строка текста; exit 0 всегда (кроме плохих аргументов). Тиры: `80→90→95→99` (основное окно), `70→85→95` (weekly). Каждый тир один раз, пере-вооружается при спаде usage. Формулировка «как спросить» по агенту — `cnt_ask_hint`.
3. **Адаптер Claude** (`adapters/claude/`): `stop.sh` (Stop-событие → `check` → blocking JSON), `tool-check.sh` (PostToolUse → `check` → `additionalContext`, посреди хода; молчит в сабагентах по `agent_id`; флаги общие со Stop), `frugal-gate.sh` (в `CONTINUUM_FRUGAL=1` блокирует `Agent`), `stop-failure.sh` (StopFailure rate_limit → `continuum limit-hit`), `statusline.sh`, `setup-statusline.sh`, `resume-report.sh` (+ `.ps1`). `hooks/*.sh|ps1` — форвардеры для старых конфигов, удалить в v0.8 (в v0.7.0 оставлены, чтобы релиз адаптеров не ломал старые settings.json).
4. **Skill** (`skills/session-budget/SKILL.md`) — что делать при предупреждении: показать ситуацию, спросить пользователя через AskUserQuestion (на его языке), никогда не решать за него. Опции: wrap up / finish batch / save+resume / frugal / cheap-only / ignore.
5. **`continuum resume`** — планирует headless-команду агента после ресета: `CONTINUUM_RESUME_CMD` → пресет `CONTINUUM_AGENT` (по умолчанию `claude`; пресеты других агентов появятся с их адаптерами) → ошибка. Планировщик по ОС: launchd / systemd-run / daemon(8) / detached process / nohup-fallback. Вейклок + нотификация.
6. **Состояние** — `CNT_STATE`: `$CONTINUUM_STATE_DIR` → `$XDG_STATE_HOME/continuum` → `~/.local/state/continuum` (одинаково в sh и ps1). НЕ `~/.continuum` — там код от инсталлятора (`CONTINUUM_HOME`). Разовая миграция из `~/.claude` (копирует conf/логи/провайдеры, не кэш; маркер `.migrated`). `$CNT_STATE/root` — указатель на код для скриптов без окружения (копия statusline в `~/.claude/hooks/`). Токен Claude (`~/.claude/.credentials.json`) ищет провайдер `anthropic`, не ядро.

Плюс: **statusline** (`hooks/statusline.sh`) — % в статус-баре Claude Code: зелёный <80%, жёлтый 80–94%, красный ≥95%. Формат настраивается (`continuum statusline format ...`).

## Карта репо

- `bin/continuum`, `bin/continuum.ps1` — CLI (status/reset/estimate/watch/history/cleanup/providers/statusline/resume).
- `adapters/claude/` — Claude Code адаптер (stop, tool-check, frugal-gate, statusline, setup-statusline, resume-report + `.ps1`).
- `adapters/{codex,gemini,cursor}/` — конец хода + после инструмента (`.sh` + `.ps1`), общий `adapters/lib.sh|ps1`; `adapters/opencode/continuum.js` (тест — `tests/opencode.mjs` под node). У каждого `README.md` с готовым конфигом.
- `hooks/hooks.json` — манифест хуков плагина (указывает в `adapters/claude/`); `hooks/*.sh|ps1` — форвардеры совместимости.
- `lib/core.sh`, `lib/core.ps1` — общая логика (провайдеры, кэш, JSON-парсинг).
- `providers/` — `anthropic.sh`, `mock.sh`, `spend.sh`.
- `skills/session-budget/`, `skills/auto-resume/` — скиллы плагина.
- `tests/run.sh`, `tests/run.ps1` — единый сьют, mock-провайдер, без сети.
- `docs/harnesses.md` (агенты + «Writing an adapter»), `docs/writing-a-provider.md` — доки.
- `docs/superpowers/specs/` — спеки (пайплайн и шаблон в `README.md` там же); `2026-09-24-agent-neutral-core-design.md` — agent-agnostic, `2026-10-26-roadmap.md` — что дальше.
- `docs/agents/issue-tracker.md` — где ревью ищет спеку; `.github/pull_request_template.md` — чеклист PR.
- `README.md` (EN) + `README.ru.md` (RU) — держать синхронно, шапка центрированная, лого `assets/logo.png` 120px.
- `.remember/` — автопамять Claude-плагина remember (now.md / today-*.md / recent.md / archive.md). Только для Claude; кросс-агентная правда — этот файл.

## Команды

```sh
sh tests/run.sh          # 250 тестов, mock, без сети (эталон; проходит и под dash)
pwsh tests/run.ps1       # 196 тестов, та же сюита для PowerShell
continuum status         # 5h 86.5% resets at 21:40 + weekly строка
continuum reset          # HH:MM ресета (+90s, для планировщика)
continuum estimate       # сколько осталось at this pace
continuum watch          # опрос в отдельной панели, bell на пороге
continuum history        # последние 20 снапшотов
continuum check --session ID --agent claude  # ядро предупреждения для любого агента
continuum resume "$(continuum reset)" "$PWD" "конкретная задача"  # NEVER generic "continue"
```

## Текущее состояние (2026-10-27)

- **Не выпущено (локальные коммиты после v0.7.4, ждут команды на bump + push):** R1.3 `continuum watch --ide` (предупреждение в JetBrains IDE через её MCP: `.git/continuum-warning.md` + `open_file_in_editor`; проверено вживую в Rider), R5 `continuum install|uninstall --agent codex|gemini|cursor|opencode` (без JSON-парсера: создать / вставить в файл без `"hooks"` с бэкапом / иначе отказ; uninstall по контрольной сумме; симлинки не трогает), R6 провайдер `openrouter` (`GET /api/v1/key`, ключ только из `OPENROUTER_API_KEY`, `CONTINUUM_OPENROUTER_CAP` для ключа без лимита; вживую не проверен — ключа нет), CI: установка PSScriptAnalyzer с повторами (флак PSGallery на Windows). R2 частично (`docs/live-checks.md`), R1.1 ждёт RustRover + свободный лимит Claude. **Тесты: sh 250/250 (и под dash), ps 196/196.**

- **v0.7.4 — R3 `continuum doctor [--fix]`** (спека `…/2026-10-26-r3-doctor.md`): ok/warn/fail/skip по строке, exit 1 только на fail. Провайдер, каталог состояния, указатель на код, плагин в `enabledPlugins`, старые хуки (`token-budget-check.sh`, `.claude/lib/usage.sh`, `hooks/continuum-check.*`), копия statusline, **версия плагина, которую реально запускает Claude Code** (`~/.claude/plugins/cache/continuum/continuum/<ver>`), версия расширения Junie. `--fix` — только копия statusline и указатель; `settings.json` не трогает. На этой машине сразу показал: плагин и Junie на 0.7.0. Секьюрити-автофикс (находка автоматического ревью): значения в plist launchd не XML-экранировались — каталог `x</string></array><key>Program</key>…` перестраивал задание; теперь экранирование поверх shell-квотинга + тест на macOS (`plutil`). В `.ps1` экранирован путь pid-файла вейклока. **Тесты: sh 213/213 (и под dash), ps 171/171.**

- **v0.7.3 — R4: лимит кончился посреди хода** (спека `docs/superpowers/specs/2026-10-26-r4-stopfailure-rate-limit.md`, первая по пайплайну). Хук `StopFailure` (matcher `rate_limit`, Claude Code и Junie) → `adapters/claude/stop-failure.sh|ps1` → ядро `continuum limit-hit [session] [agent] [dir]`: уведомление, строка `### limit hit` в логе resume, заметка `.continuum-limit-notes` → `resume-report.sh` покажет при следующем старте один раз. Окно — то, что исчерпано (по кэшу, без сети). С `CONTINUUM_RESUME_ON_LIMIT=1` (согласие заранее) ещё и `continuum resume` на сброс по пресету агента, только если сброс в ближайшие 24 ч, один на каталог за окно. `CONTINUUM_NOTIFY_CMD` подменяет уведомлялку. Секьюрити-автофиксы: текст уведомлений шёл в исходник AppleScript (`osascript -e "display notification \"$msg\""`) → теперь argv (3 места); управляющие символы из имени каталога вычищаются (нельзя подделать строки заметок/контекста). `continuum cleanup` чистит `.continuum-limit-*`. **Тесты: sh 197/197 (и под dash), ps 160/160.**

## Ранее (2026-10-26)

- **v0.7.2 — выпущен 2026-10-26** (тег + GitHub Release, CI зелёный на 6 джобах; включает v0.7.1: bb + сброс недельного окна). **Junie (JetBrains) + фиксы**: Junie CLI ставит Claude-плагины как расширения и гоняет их `hooks/hooks.json` (`${CLAUDE_PLUGIN_ROOT}`), так что отдельных скриптов нет — Claude-адаптер узнаёт Junie по `project_path` в событии → `--agent junie` (свой hint: вопрос в конце итогового сообщения, без AskUserQuestion). Junie не шлёт `PostToolUse` → `tool-check.sh` подключён и на `PreToolUse` (в Claude сразу выходит). `setup-statusline.sh` в Junie ничего не делает. Пресет `junie --skip-update-check --resume --task "{prompt}"`. Вживую (Junie CLI 26.10.20, batch): Stop-предупреждение дошло, `--resume --task` продолжает ту же сессию. В IDE (RustRover и др.) агент чата — по выбору, всё через ACP: Junie там хуки не вызывает (их доки), Claude Agent / Codex в чате ещё не проверены (беклог: если их ACP-мост грузит пользовательские хуки, как Agent SDK в bb, — работает без доработок). Доки `adapters/junie/README.md`. Плюс фиксы: 30-сек гейт statusline — метка `$cache.at` вместо `find -mmin -0.5` (bfs на macOS его не понимал → запрос на каждую отрисовку); уборка `$cache.<pid>.tmp` старше 10 мин (sh + ps1); PSScriptAnalyzer: `$event`→`$hookEvent` (автопеременная), `Invoke-History`→`Invoke-CntHistory` (перекрывал командлет); CI `actions/checkout@v5`. RustRover подключён к Claude Code как MCP `rustrover` (`http://127.0.0.1:64522/stream`, как `rider`). **Тесты: sh 180/180 (и под dash), ps 150/150.**

- **v0.7.1 — bb + сброс недельного окна**: bb (`/Applications/bb.app`, CLI `~/.bb/bin/bb`) — оболочка над агентами, своих хуков не нужно: треды Claude Code идут через Agent SDK с `settingSources: user/project/local` (`~/.bb/plugin-host-artifacts/provider-claude-code/*/host.mjs`) → плагин continuum подгружается; Codex читает свои хуки. В ядре: при `BB_THREAD_ID` (bb ставит его агенту) `continuum resume` → `<абсолютный путь>/bb thread tell <id> "{prompt}"` (после `CONTINUUM_RESUME_CMD`, до пресета агента; id валидируется `[A-Za-z0-9_-]`; путь абсолютный, т.к. у launchd короткий PATH). Доки `adapters/bb/README.md`. По отзыву 2026-10-26: предупреждение недельного окна называет его сброс («resets Fri 18:28», `cnt_epoch_dayhhmm` / `ConvertTo-CntDayHhmm`). **Тесты: sh 165/165 (и под dash), ps 141/141.** bb вживую не проверен. В репо подключён RustRover (`.idea/`).

- **v0.7.0 — адаптеры Codex CLI, Gemini CLI, Cursor, opencode** (подпроекты 2–4): протоколы взяты из официальных доков (Codex `Stop` block / `PostToolUse` additionalContext; Gemini `AfterAgent` deny / `AfterTool` additionalContext; Cursor `stop` followup_message / `postToolUse` additional_context; opencode `session.idle` → `client.session.prompt`, `tool.execute.after` → дописать в output). Пресеты resume для всех четырёх (Codex сверен с `codex exec resume --help` 0.164.0; остальные — по докам). Cursor без `--force` (ревью безопасности: `--force` = любые команды без присмотра; opt-in через `CONTINUUM_RESUME_CMD`). **Вживую ни один не запускался** — локально есть только opencode, а в нём только платные OpenRouter/xAI. **Тесты: sh 160/160 (и под dash), ps 136/136.**

- **v0.6.3 — проверка порога внутри хода**: `adapters/claude/tool-check.sh|ps1` на `PostToolUse` → `continuum check` → `hookSpecificOutput.additionalContext` (не блокирует). Флаги общие со Stop, молчит в сабагентах (`agent_id`), ~0.1 с на вызов при свежем кэше. Проверено вживую через `claude -p --plugin-dir .` с mock. Коммит прямо в `main` по просьбе пользователя, тег — после зелёного CI. **Тесты: sh 137/137 (и под dash), ps 114/114.**

- **v0.6.2 — фикс v0.6.1**: проверка устаревшего кэша (после ресета / старше 10 мин) в `statusline.sh` стояла за 30-сек гейтом `find -mmin -0.5` — кэш, записанный за <30с до ресета, после ресета показывал старые цифры. Локально не ловилось: на macOS `find` = `bfs`, он не понимает дробный `-mmin` (гейт всегда открыт); на CI GNU find падал в 4 тестах. **Урок: мержить только при зелёном CI.**
- **v0.6.1 — патч статус-бара**: устаревший кэш (нет / старше 10 мин / после ресета) обновляется синхронно до первой отрисовки — новая сессия сразу показывает актуальные цифры; после неудачи — маркер `.continuum-cache-<prov>.retry`, 2 мин бэкофф (иначе оффлайн вешал бы каждую отрисовку до 15с). Плюс фикс двойного `%` (`86%%`) и атомарная запись кэша в `.ps1`. **Тесты: sh 124/124 (и под dash), ps 102/102**, shellcheck чист.
- **v0.6.0 — agent-agnostic, подпроект 1 из 5**: ветка `feat/agent-neutral-core` → PR в `main`, тег `v0.6.0` на merge-коммите. Первый тег в репо (до этого релиз = bump-коммит).
- Сделано: agent-нейтральное ядро (`continuum check`, `CNT_STATE` + миграция из `~/.claude`, root-указатель, пресеты resume) + `adapters/claude/`. **Тесты: sh 114/114 (и под dash), ps 91/91**, shellcheck чист, e2e-установка в изолированный HOME проверена.

## Прогресс последней недели

- 16.09: wakelock, README v0.5.0 En/Ru, statusline 30s-кэш, BSD, bump версии, лого/иконки — запушено.
- 17.09: rebase/push `14cf032`, README-рерайт + resume-no-commit, statusline race-fix (tmp+atomic mv) + `continuum statusline config`, 63/63 на тот момент.
- 18–20.09: code-review hardening, PS statusline + конфиг, 84/84, merge PR #1 (`e2e6085`). Детально — `.remember/today-2026-09-1*.md`, `recent.md`.
- 24.09: agent-agnostic, подпроект 1 (ядро + Claude-адаптер), 114/91 тестов, релиз v0.6.0.
- 30.09: v0.6.1 — статус-бар свежий с первой отрисовки (+бэкофф при сбое), фикс `86%%`, ревью безопасности, 124/102 тестов.
- 02.10: merge PR #3 с красным CI → v0.6.2: stale-проверка перед 30-сек гейтом (GNU find), 124/102.
- 23.10: два отзыва «лимит внутри хода» → миграция машины на плагин, GitHub Release v0.6.2, README-рерайт (PR #5, «What it touches»), проверка порога внутри хода (`tool-check.sh`, PostToolUse), 137/114.

## Дальше (беклог, по приоритету)

Порядок и требования — `docs/superpowers/specs/2026-10-26-roadmap.md` (R4 StopFailure + resume по согласию заранее → R3 doctor → R2 живые проверки → R1 JetBrains-чат → R5 install → R6 провайдер). Каждый пункт — своя спека до кода.

0. **Из feedback 2026-10-23 (лимит внутри хода, `feedback/2026-10-23-claude-limit-{mid-turn,long-turn}.md`, два случая подряд)**:
   - ~~Проверка порога внутри хода~~ — сделано 2026-10-23 (`tool-check.sh`, PostToolUse). Не сделано: отдельный жёсткий блок `Agent` выше порога — посмотреть по отзывам, хватает ли мягкого предупреждения.
   - **`continuum doctor`**: подключённый коммит, включён ли плагин (`enabledPlugins`), legacy-хуки (`token-budget-check.sh`, `~/.claude/lib/usage.sh`), дрейф копии statusline + одна команда миграции. Связано с п.4.
   - **Auto-resume по 429 внутри хода**: у Claude Code есть событие `StopFailure` (matcher `rate_limit`), без decision control — спросить пользователя нельзя. Вариант: по нему писать заметку/уведомление «лимит, сброс в HH:MM, `continuum resume …`», а не планировать молча (resume без согласия нарушает принцип «не решать за пользователя»).
   - ~~Мусор `*.tmp`~~ — сделано в v0.7.2.
1. **Живая проверка новых адаптеров** (Codex, Gemini, Cursor, opencode): по одной сессии с `CONTINUUM_THRESHOLD=10 CONTINUUM_TIERS=10` + mock-провайдер; по итогам — строка «run live» в README/harnesses. Отдельно: есть ли у агентов инструмент вопроса (тогда строка в `cnt_ask_hint`).
2. ~~Адаптеры Codex / opencode / Cursor / Gemini~~ — сделано 2026-10-24, v0.7.0.
3. —
4. **`continuum install --agent <x>`** + доки (подпроект 5); заодно проверить marketplace-установку с нуля.
5. **Новый провайдер** — OpenAI или Gemini по `docs/writing-a-provider.md` (отдельная ось от агентов).
6. Мелочи: `continuum cleanup` от `.DS_Store`-мусора? ~~30-сек гейт на bfs, checkout@v4~~ — сделано в v0.7.2. PSScriptAnalyzer из PSGallery иногда не ставится.

## Feedback от агентов (обязательно)

- Папка `feedback/` — отзывы любого агента, который пользовался continuum. В git не коммитится (кроме `README.md`).
- После каждого meaningful использования оставь отзыв: `feedback/YYYY-MM-DD-<агент>-<тема>.md` по шаблону из `feedback/README.md`.
- В начале каждой рабочей сессии проверь новые файлы в `feedback/` (по mtime, которых ты ещё не видел) и учти их при планировании; годное переноси в раздел «Дальше».

## Утренний протокол («что дальше делаем?»)

1. Прочитай «Текущее состояние» и «Дальше» выше.
2. `git log --oneline -5 && git status -sb`, загляни в `.remember/now.md`, проверь новые файлы в `feedback/`.
3. Если `main` грязный или отстаёт — скажи об этом первым.
4. Предложи 1 следующий шаг из беклога + команду для старта. Без новых скоупов, пока не закроем выбранное.

## Пайплайн (spec-first, обязательно)

Подробно и шаблон — `docs/superpowers/specs/README.md`.

1. **Спека** → `docs/superpowers/specs/YYYY-MM-DD-<тема>.md` (требования R1..Rn, out of scope, acceptance). Отдельный коммит `docs(spec): …`. Без согласованной спеки код не пишем.
2. **Код** по требованиям; в каждом коммите трейлер `Spec: docs/superpowers/specs/<файл>.md`.
3. **Ревью** — `/code-review <base>`: две оси, Standards (AGENTS.md/README) и Spec (недоделанные требования, лишнее, неверная реализация). Спеку скилл находит по трейлеру (`docs/agents/issue-tracker.md`).
4. **Автофиксы** — сразу после ревью, без вопросов, агент правит то, что сочтёт нужным (в т.ч. находки ниже порога отчёта: hardening, мелкие баги, устаревшие комментарии). Границы: в рамках спеки и не нарушая её (без нового поведения и смены скоупа), sh+ps1 вместе, обе сюиты зелёные. Правка, меняющая спеку, — не автофикс: спросить или в «Later». **Любые проблемы безопасности** (секреты в коде/логах, инъекции, небезопасные пути/права, данные сверх раскрытого в «What it touches») — всегда автофикс, любой серьёзности, даже если сужают поведение; «What it touches» обновить в том же коммите. Отчёт — по строке на фикс.
5. **Исправление** — оставшиеся находки обеих осей исправить и прогнать ревью снова, пока не чисто. Верное, но вне скоупа — в раздел «Later» спеки. Поменялось решение — правим спеку в том же коммите.
6. **Релиз** — тесты обеих сюит, `claude plugin validate .`, локальный коммит с трейлером `Spec:`. **Повышение версии и push — только по явной команде пользователя** (а с ними тег, GitHub Release и переписывание README); готовая спека не означает ни того, ни другого. По команде: bump, push, зелёный CI, тег + Release, оба README; статус спеки `done (vX.Y.Z)`.

Мелочи (опечатка, однострочный фикс, только доки) — без спеки, с пометкой в коммите.

## Конвенции (обязательно для всех агентов)

- Правки в файлы — сразу, без запроса подтверждений. Shell-команды — всегда одной строкой, без переносов.
- Поиск/чтение — встроенными Read/Grep/Glob; связи кода — через code-review-graph, если настроен.
- POSIX `sh`, без зависимостей; каждая правка `.sh` дублируется в `.ps1` (и наоборот) + тесты в обе сюиты.
- README агент-нейтрален: общая часть (Install, What it touches, Agents, How it works, Configuration…) не про конкретного агента; всё агент-специфичное (установка плагина, хуки, settings, статус-бар, Windows-оверрайды) — только в разделе агента (`## Claude Code`) и в `adapters/<агент>/README.md`. Новый адаптер = новый такой раздел. Упоминания провайдера `anthropic` (токен Claude Code) — это факт провайдера, они остаются в общей части.
- README.md и README.ru.md — всегда синхронны по смыслу. **На каждом релизе** (тег + GitHub Release с заметками) оба README переписываются под текущее состояние (версия, тесты, фичи, ограничения, раздел «What it touches»), затем `claude plugin validate .`.
- Каталог плагинов Anthropic: подача через developer portal `claude.ai/directory/manage` (Plugin bundle, репо целиком = папка плагина). Требования: README ≥40 слов, LICENSE, нет `.DS_Store` в git, файлы <256 KiB; security-скан сверяет поведение с README → всё, что плагин шлёт/читает/меняет, раскрыто в «What it touches». Чтение токена Claude с машины, скорее всего, даст «Policy hold» (ручное ревью), не блок.
- Коммиты — только по явной просьбе (или как шаг пайплайна). **Повышение версии и `git push` — только по команде пользователя.** Формат conventional commits. Никаких секретов в коде.
- Мелкие текстовые задачи (перефразировка, кейс-конверсия, тестовые данные) — через `ask_apfel` (on-device), не своей генерацией.
