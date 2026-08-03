# Worktree toolkit — швидкий старт

Кожна гілка — окремий git worktree поруч з основним чекаутом
(`~/dev/hopecloud.worktrees/feat-dt123-thing`) зі своєю Postgres, портами і Caddy.
Закінчив задачу — archive: БД дропається, worktree і гілка видаляються.

## Користування

| Дія | agterm | Claude Code | CLI |
|---|---|---|---|
| Новий worktree | ⌘⌥T | `/worktree feat/dt123-thing [base]` | `wt=$(~/.config/harness/worktree-create.sh 'feat/dt123-thing' master)`<br>`cd "$wt" && ~/.config/harness/worktree-setup.sh 'feat/dt123-thing'` |
| Архівувати | ⌘⌥⇧T (з сесії worktree) | `/worktree-archive` | `~/.config/harness/worktree-archive.sh <шлях-до-worktree>` |

- base за замовчуванням `master`; `.` = поточна гілка.
- Скіли працюють і з телефона (Remote Control); якщо екран Mac заблокований, сесія
  підніметься в detached tmux — `tmux attach -t <slug>` за Mac'ом.
- Archive — деструктивний: зносить незакомічені зміни. Основний чекаут і
  `master`/`dev` захищені завжди.

## Встановлення собі

1. Скопіюй у `~/.config/harness/`: `worktree-create.sh`, `worktree-setup.sh`,
   `worktree-archive.sh`, `worktree-open-session.sh` (+ опційно `worktree-new.sh`,
   `worktree-rm.sh` для agterm-хоткеїв і `env-skip`).
2. Скопіюй скіли `worktree/` і `worktree-archive/` у `~/.claude/skills/`.
3. Залежності: zsh, git, jq, docker. Опційні: tmux, agterm, solidtime — без них усе
   само деградує коректно.
4. agterm-хоткеї — два рядки в `~/.config/agterm/keymap.conf` + `agtermctl keymap reload`:

```
command "New worktree" cmd+opt+t /opt/homebrew/bin/agtermctl session overlay open "$HOME/.config/harness/worktree-new.sh" --cwd "$AGT_SESSION_PWD" --size-percent 80 --background-color "#27363F" --follow
command "Remove worktree" cmd+opt+shift+t /opt/homebrew/bin/agtermctl session overlay open "$HOME/.config/harness/worktree-rm.sh" --cwd "$AGT_SESSION_PWD" --size-percent 80 --background-color "#6B212C" --follow
```

Все інше — механіка, контракти скриптів, обробка збоїв — у [AGENTS.md](AGENTS.md):
це гайд для агента, згодуй його своєму Claude (як skill або просто в контекст).
