# worktree — git worktree на кожну гілку, з оточенням і teardown

## Що це робить

Кожна гілка отримує окремий worktree поруч з основним чекаутом
(`~/dev/hopecloud.worktrees/feat-dt123-thing`) зі своєю Postgres, портами і Caddy —
паралельні задачі не заважають одна одній. Закінчив — archive: БД дропається,
worktree і гілка (локальна, опційно remote) видаляються. Захист від пострілу в ногу
вбудований: основний чекаут і `master`/`dev` не зносяться ніколи.

## Файли (скрипти лежать тут же, поруч)

| Файл | Роль |
|---|---|
| `worktree-create.sh` | Ядро створення: `<branch> [base]` → worktree; stdout = його шлях |
| `worktree-setup.sh` | Провіжининг: `infra/worktree/setup.sh` репо або fallback (.env-симлінки + install) |
| `worktree-archive.sh` | Ядро teardown: БД + worktree + локальна гілка; друкує `ARCHIVED …` |
| `worktree-open-session.sh` | agterm: нова сесія у worktree (tmux-fallback); поза agterm — no-op |
| `worktree-new.sh` / `worktree-rm.sh` | Інтерактивні overlay-обгортки для agterm-хоткеїв |
| `rc-name.sh` | Слаг гілки → коротке ім'я Remote Control сесії (тікет першим, ~30 символів); кличуть його обидва відкривачі сесій |
| `env-skip.example` | Шаблон списку апок, які пропускати при env sync |
| `AGENTS.md` | Гайд для AI-агента: контракти, процедури, інваріанти |

## Вимоги

zsh, git, jq; docker CLI (для archive). Опційні: pnpm/yarn/npm (провіжининг), tmux
(fallback з телефона), agterm (хоткеї/сесії), solidtime (тайм-трекінг — без нього
все мовчки скіпається).

## Встановлення

```sh
mkdir -p ~/.config/harness
cp worktree-*.sh rc-name.sh ~/.config/harness/ && chmod +x ~/.config/harness/worktree-*.sh ~/.config/harness/rc-name.sh
# опційно: cp env-skip.example ~/.config/harness/env-skip   (і впиши свої апки)
```

Шлях `~/.config/harness/` захардкоджений у скриптах — або тримай його, або заміни
всюди. Для Claude Code: згодуй `AGENTS.md` агенту (як skill чи просто в контекст) —
цього достатньо, щоб він водив увесь флоу.

agterm-хоткеї — два рядки в `~/.config/agterm/keymap.conf` + `agtermctl keymap reload`:

```
command "New worktree" cmd+opt+t /opt/homebrew/bin/agtermctl session overlay open "$HOME/.config/harness/worktree-new.sh" --cwd "$AGT_SESSION_PWD" --size-percent 80 --background-color "#27363F" --follow
command "Remove worktree" cmd+opt+shift+t /opt/homebrew/bin/agtermctl session overlay open "$HOME/.config/harness/worktree-rm.sh" --cwd "$AGT_SESSION_PWD" --size-percent 80 --background-color "#6B212C" --follow
```

## Користування

| Дія | agterm | AI-агент | CLI |
|---|---|---|---|
| Новий worktree | ⌘⌥T | «новий worktree feat/dt123-thing» | `wt=$(worktree-create.sh 'feat/dt123-thing' master)`<br>`cd "$wt" && worktree-setup.sh 'feat/dt123-thing'` |
| Архівувати | ⌘⌥⇧T (з сесії worktree) | «заархівуй worktree» | `worktree-archive.sh <шлях-до-worktree>` |

base за замовчуванням `master`; `.` = поточна гілка репо.

## Межі

- Archive — деструктивний: зносить незакомічені зміни у worktree. Агент за
  `AGENTS.md` зобов'язаний показати, що буде втрачено, і спитати підтвердження.
- Ізольована БД/порти працюють у репо з `infra/worktree/setup.sh` + `archive.sh`;
  інші репо отримують мінімальний fallback.
- Скрипти розраховані на macOS + zsh (`print`, `${var:t}` тощо) — на bash/linux
  треба портувати.
