# AEM Watch UI Toolkit 团队仓库规则

## 仓库边界

- 本仓库是团队 Marketplace 与 `aem-watch-ui-toolkit` Plugin 的唯一维护源；Codex 安装缓存和产品仓库中的副本不得反向覆盖这里。
- 只保存跨项目稳定的 AEM Watch UI 约定、资源事务、脚本、参考文档和配置模板。
- 禁止写入具体产品的 application、board、resolution、绝对工程路径、功能开关、分支计划或一次性页面参数。
- 产品差异通过产品仓库自己的 `AGENTS.md`、项目 wrapper 和资源 JSON 提供。

## 修改约束

- 修改现有 Skill 前先搜索同义规则，优先合并或修正，避免重复入口和相互矛盾的流程。
- 通用资源 Skill 接收调用方已经解析好的 Action、ConfigPath 和 ManifestPath；不得重新搜索或覆盖产品规则。
- 不把普通 C/C++ UI 修改自动扩大为资源生成、翻译表写入、编译、烧录或设备操作。
- 保留用户已有修改，不清理与当前任务无关的文件。

## 脚本写入与验证

- 新增或替换 `.ps1`、`.py` 时，先在最终目录写入完整明文 `.txt`，确认路径、内容、编码且不是 `E-SafeNet` 包装后，再改为最终扩展名。
- `.ps1` 改名之前执行 PowerShell 语法解析；`.py` 改名之前执行 Python AST 检查。替换失败时保留原文件，不强制覆盖。
- 修改资源生成脚本后运行其自测；发布前验证两个 Skill、Plugin 结构及所有 PowerShell/Python 脚本。

## 版本与发布

- `.codex-plugin/plugin.json` 使用语义化版本；本地 cachebuster 只用于重新安装验证，不作为正式版本提交。
- Marketplace 名称固定为 `aem-watch-team`，Plugin 名称固定为 `aem-watch-ui-toolkit`。
- 未经用户当前任务明确要求，不添加远端、不提交、不推送、不发布版本。
