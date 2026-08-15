# 里程碑 M5 · Apple 生态（暂缓，F）

> 状态：⏸️ **暂缓**（决策 2026-08-15，见 `docs/productization.md` §2 F）
> 周期：待定（触发时启动）
> 来源：`docs/productization.md` —— §2 F、§6、§7.2、§8.2 / §8.5、§14 M5
> 更新：2026-08-15
> 注意：本里程碑**不阻塞 M1–M4**；仅在产品需要时启动。

## 目标

补齐 Apple 生态的信任与分发能力：Developer ID 签名、公证、Sparkle App 自动升级、Homebrew Cask 上架。

## 触发条件（满足其一即启动）

- 正式对外推广 / 用户量增长
- Homebrew Cask 成为分发刚需
- 需要 App 自动升级（当前用户只能手动下载新版本 + 右键打开）

## 交付物（届时实施）

| 类别 | 交付物 | 参考 |
|---|---|---|
| 账号与证书 | 注册 Apple Developer Program（个人 $99/年），申请 Developer ID 证书 | §6.2 |
| 签名公证 | Developer ID 签名 + `notarytool` 公证 + stapling；`.pkg` / `.dmg` 一并公证 | §6 |
| 运行时迁出 | 可升级运行时迁出签名包 → `~/Library/Application Support/oh-my-dsh/runtime/`（**可提前做，非阻塞**） | §6.3 |
| App 自动升级 | Sparkle 2 + EdDSA 签名 appcast（主 feed GitHub Pages + 国内镜像） | §8.2 / §8.5 |
| 上架 | Homebrew Cask 提交 | §7.2 |

## 验收标准（届时）

- [ ] Gatekeeper 零拦截安装（`spctl --assess` 通过）
- [ ] App 自动升级「发现 → 下载 → 安装 → 重启」闭环可用
- [ ] Homebrew Cask 合入
- [ ] productization.md §11.2 发布验收清单全项恢复执行

## 实施步骤（届时，任务分解）

1. **账号与密钥**（0.5 天）：注册账号、申请 Developer ID 证书、CI Secrets 配置（p12 + notarytool API key）
2. **运行时迁出**（1–2 天，若未提前做）：迁移逻辑（检测旧包内运行时 → 复制到 Application Support）、DSH_CLI/DSH_NODE 覆盖保留
3. **公证流水线**（1 天）：release.yml 接入签名 → notarytool → stapler → 产物
4. **Sparkle 集成**（2–3 天）：公钥嵌入、appcast 生成、通道策略（stable / beta）、更新策略（24h 节流，与 dsh 层一致）
5. **双重校验**（0.5 天）：Sparkle EdDSA + 公证校验
6. **Homebrew Cask**（0.5 天）：cask 提交 PR + appcast stanza
7. **全量发布演练**（1 天）：干净机安装 → 自动升级 → 回滚预案验证

## 依赖与前置

- Apple 开发者账号（唯一硬依赖）
- 运行时迁出可提前在 M1–M4 任意时间完成（不依赖账号）
- 与 M1–M4 完全解耦，独立排在最后

## 风险与注意点

| 风险 | 缓解 |
|---|---|
| $99/年成本 | 触发时才投入；暂缓期零成本 |
| 公证流程摩擦 | CI 自动化 + 官方文档（§6 保留方案） |
| 升级破坏包签名 | 运行时迁出后包保持密封（§6.3） |
| 国内 appcast 可达性 | 主 feed GitHub Pages + 国内镜像 feed（§8.5） |

## 测试与验收

- 干净 macOS：首次安装无 Gatekeeper 拦截；自动升级到新版本；升级后签名校验通过
- 回滚预案：升级失败自动回滚并保留旧包日志
- 完成标志：本文件「验收标准」全勾选 + productization.md §2 F 退出标准达成

## 关联文档

- `docs/productization.md`：§2 F、§6、§7.2、§8、§11.2
- `docs/milestones/M1-productization-foundation.md`（CI / release 钩子预留）
