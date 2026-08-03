# cookbooks

Практичні рецепти мого dev-тулінгу — за зразком [agterm cookbook](https://github.com/umputun/agterm/tree/master/cookbook):
кожен рецепт — самодостатня тека зі скриптами і двома доками: `README.md` (людині —
що це, як поставити, як користуватись) + `AGENTS.md` (AI-агенту — контракти скриптів,
процедури, інваріанти; згодовується як skill або контекст).

| Рецепт | Що робить | Потребує |
|---|---|---|
| [worktree/](worktree/) | git worktree на кожну гілку з ізольованим оточенням (БД/порти) — створення і архівація | zsh, git, jq, docker; опційно agterm, tmux, solidtime |
