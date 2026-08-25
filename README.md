# AEM Watch UI Toolkit Marketplace

这是 AEM Watch 团队共享的 Codex Marketplace 仓库。它只维护可跨项目复用的 UI 约定和资源事务；application、board、resolution、资源路径、功能开关和迁移阶段由各产品仓库提供。

## 包含内容

- `$aem-watch-ui-toolkit:aem-watch-ui-conventions`：LVGL 页面实现、生命周期、刷新、失败处理和公共控件约定。
- `$aem-watch-ui-toolkit:aem-watch-resource-pipeline`：由项目 JSON 驱动的 WPS 翻译表、UI Editor、资源状态、备份、回滚和 Post 检查。

Plugin 源位于 `plugins/aem-watch-ui-toolkit/`；`.agents/plugins/marketplace.json` 是 Codex 的团队 Marketplace 入口。不要从 Codex 缓存目录复制或维护另一份实现。

## 安装

1. 克隆完整仓库，不要只复制 `plugins/` 或某个缓存版本目录。
2. 首次添加团队 Marketplace：`codex plugin marketplace add <repository-root>`。
3. 安装 Plugin：`codex plugin add aem-watch-ui-toolkit@aem-watch-team`。
4. 安装或升级后新建 Codex 任务，再进入产品仓库工作。

产品仓库应声明验证过的 Plugin 版本，并保留自己的 `AGENTS.md`、项目资源 JSON 和项目 wrapper。缺少项目配置、所需 Skill 不可见、版本不匹配或存在同名重复 Skill 时，不执行资源写入。

## 本机配置

WPS、Python 和其他安装路径属于使用者本机配置。根据 `plugins/aem-watch-ui-toolkit/skills/aem-watch-resource-pipeline/assets/local-config.template.json` 创建 `%USERPROFILE%/.codex/config/aem-watch-resource-pipeline.local.json`，不要提交到 Plugin 或产品仓库。WPS 不可用时只暂停翻译表步骤并请求用户补充路径。

## 维护与发布

- 通用流程只在本仓库维护；产品仓库只保存自己的规则、wrapper 和项目 JSON。
- 修改 Skill 后运行 Skill 校验；修改 Plugin 后同时运行 Plugin 校验、PowerShell 语法解析、Python AST 和相关自测。
- 发布版本使用语义化版本；本地迭代安装可临时使用 Codex cachebuster，正式提交前恢复干净版本号。
- 提交前确认仓库中没有产品绝对路径、本机配置、缓存、生成诊断或临时 `.txt` 脚本。
- 推送远端和发布版本必须由维护者明确执行，不随普通本地验证自动进行。
