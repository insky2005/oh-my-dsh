# .dsh/tools

## derive-status.mjs —— 交付结果派生

**只读**:读事项 / 需求卡片 + 查 PR 状态,算出 `outcome` / `closed`。终态是谓词,**不写回卡片**。

```sh
GH_TOKEN=$(cat "$HOME/.dsh/oh-my-dsh/tokens/<owner>-<repo>") node .dsh/tools/derive-status.mjs
```

- 令牌:优先环境变量 `GH_TOKEN`,否则 `~/.dsh/oh-my-dsh/tokens/<owner>-<repo>` / `~/.dsh/oh-my-dsh/gh-token`;
- 仓库:环境变量 `DSH_REPO=owner/repo`,否则由 `git remote`(github / origin)推导;
- `outcome`:由 PR 状态派生(merged / open / closed);显式 `abandoned` 亦可;
- 无令牌 / 无网络 → 输出 `unknown`,**不假装成功**。