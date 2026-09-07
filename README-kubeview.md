# kubeview

Терминальный drill-down UI над `kubectl` (движок — `fzf`). Чтение —
`get` / `describe` / `logs`; **Enter по поду открывает в нём shell**
(`kubectl exec -it`).

```
╭─ kubeview · выбор kubeconfig ───────────────────────────────╮
│ ◆ config          → context-a                              │   preview:
│ ◆ config-staging  → context-b                              │   config get-contexts
│ ◆ config-prod     → ?                                       │   cluster-info
╰────────────────────────────────────────────────────────────╯
        │ Enter
        ▼
╭─ namespace ────────────────────────────────────────────────╮
│ kubeconfig: config-staging   ←/→ сменить файл              │   preview: счётчики
│ ● default        Active                                    │   pods / deploy / svc
│ ● kube-system    Active                                    │
╰─ config-staging · ctx context-b · ns — ┃ nodes 4 · CPU 1.3/14 (10%) · RAM 24/41Gi ─╯
        │ Enter
        ▼
╭────────────────────────────────────────────────────────────╮
│  pods   deployments  services      ←/→ вид · ↑/↓ ресурсы    │
│╭ pods @ my-app ──────────────╮╭ logs / describe ──────────╮ │
││▶ ● api-7f86…  1/1  Running  ││ api-7f86…                 │ │
││  ● worker-…   1/1  Running  ││ node: …  ip: …            │ │
││  ○ old-pod    0/1  Evicted  ││ ── logs (--tail=200) ──   │ │
│╰─────────────────────────────╯╰───────────────────────────╯ │
╰─ config-staging · ctx context-b · ns my-app ┃ nodes 4 · CPU 1.3/14 · RAM 24/41Gi ─╯
```

## Экраны и навигация

| экран        | что                                   | клавиши                                                  |
|--------------|---------------------------------------|---------------------------------------------------------|
| kubeconfig   | файлы из `~/.kube`, распознанные как конфиг | ↑/↓ выбор · Enter открыть · **Esc — выход**. Если файл один — экран пропускается, старт сразу с namespace (Esc там = выход). |
| namespace    | namespaces выбранного конфига          | ↑/↓ выбор · **←/→ сменить kubeconfig-файл** · Enter · Esc назад |
| ресурсы      | pods / deployments / services в ns     | **←/→ переключить вид** · ↑/↓ по ресурсам · Enter · Ctrl-O · Ctrl-G · Ctrl-R · Esc назад |

Esc на каждом экране возвращает на шаг назад; на экране выбора kubeconfig — выход.

Крошки на нижней грани внешней рамки (появляются после выбора kubeconfig):

```
config-staging · ctx context-b · ns my-app   ┃   nodes 4 · CPU 1.3/14 (10%) · RAM 24/41Gi (59%)
```

- `nodes N` — число нод;
- `CPU used/alloc (%)` — сумма по всем нодам: занято (из `kubectl top nodes`,
  нужен metrics-server) / выделяемо (`allocatable`);
- `RAM used/alloc (%)` — то же по памяти, в Gi.
- Значение кэшируется на 45 c; **Ctrl-R** пересчитывает. Если metrics-server
  недоступен — показывается только `allocatable` с пометкой.

## Правая панель (preview)

- **pod** — node/ip/phase/контейнеры, затем `kubectl logs --tail=200 --all-containers
  --prefix --timestamps` и хвост секции Events из `describe`.
- **deployment / service** — полный `kubectl describe`.

## Действия

| клавиша | действие                                                        |
|---------|-----------------------------------------------------------------|
| Enter   | **pod:** `kubectl exec -it` → shell в контейнере. Ищется первый рабочий из `/bin/bash → /bin/sh → /busybox/sh → bash → sh`; если контейнеров в поде несколько — сначала их список для выбора. Distroless (нет sh) — сообщение. **deploy/svc:** полный `describe` в pager. |
| Ctrl-O  | `describe` + `logs --tail=3000` в pager (для любого вида)       |
| Ctrl-G  | `kubectl logs -f` выбранного пода (`less +F`), только для pods  |
| Ctrl-R  | обновить список                                                |
| печать  | fuzzy-фильтр по текущему списку                                |

## Запуск

```bash
./kubeview.sh
```

Другой каталог с конфигами:

```bash
KUBEVIEW_DIR=/path/to/kubeconfigs ./kubeview.sh
```

Поставить в PATH:

```bash
install -m755 kubeview.sh ~/.local/bin/kubeview
```

## Зависимости

- `kubectl` (проверено на v1.23)
- **`fzf` >= 0.53** — нужны секционные рамки `--list-border` / `--input-border`
  и `transform-*-label` (проверено на 0.74). Скрипт проверяет версию на старте
  и предлагает скачать свежий бинарь, если своего нет (`--install-fzf`,
  `KUBEVIEW_FZF=…`). Для автозагрузки нужны `curl`/`wget` и `tar`.
- `jq` — разбор `-o json` (возраст, статусы, реплики, порты, ресурсы нод).
  Regex-функции jq (`test`/`capture`) не используются — работает и без oniguruma.
- `bash` >= 4, `awk` (mawk из Ubuntu подходит)
- `metrics-server` в кластере — опционально, для колонки «занято» по CPU/RAM
  в нижней строке (без него показывается только `allocatable`)

### Ubuntu: «запускается и сразу выходит»

Почти всегда причина — **старый `fzf` из apt** (в 22.04 это 0.29, в 24.04 — 0.44;
нужен ≥ 0.53).

При старте `kubeview.sh` сам проверяет версию и, если fzf нет или он старый,
**предлагает скачать свежий бинарь** в `~/.local/bin`:

```
fzf 0.44.1 — слишком старый (нужен >= 0.53).
Скачать последний fzf в /home/user/.local/bin? [y/N]
```

Форсировать загрузку заранее: `./kubeview.sh --install-fzf`.
Указать свой бинарь: `KUBEVIEW_FZF=/path/to/fzf ./kubeview.sh`.

Ручная установка (если автозагрузка недоступна):

```bash
git clone --depth 1 https://github.com/junegunn/fzf ~/.fzf
~/.fzf/install --bin
export PATH="$HOME/.fzf/bin:$PATH"     # добавьте в ~/.bashrc
```

`jq` и `kubectl` — `sudo apt install jq` и обычная установка kubectl.

### Совсем без fzf — `kubeview-plain.sh`

Если ставить fzf нельзя, рядом лежит `kubeview-plain.sh` на `dialog`/`whiptail`.
Меню: kubeconfig → namespace → вид → ресурс → действие (логи / `logs -f` /
`describe` / shell), Cancel/Esc — шаг назад. Нет живого превью и fuzzy-поиска,
в остальном тот же набор возможностей.

Работает и с `dialog`, и с `whiptail` (в базовой Ubuntu есть `whiptail`; `dialog`
ставится `sudo apt install dialog`). При аварийном выходе экран не затирается —
показывается сообщение с паузой. Диагностика без запуска меню:

```bash
KUBEVIEW_DEBUG=1 ./kubeview-plain.sh    # какой бэкенд, какие kubeconfig нашлись
./kubeview-plain.sh
```

Все запросы к API идут с `--request-timeout=8s`, поэтому недоступный кластер
не вешает интерфейс — в списке появляется строка с текстом ошибки.
