---
name: aem-watch-resource-pipeline
description: "按项目 JSON 配置处理 AEM Watch 的正式图片资源、WPS 翻译表、bt_watch.ui、UI Editor 事务化生成和资源状态检查。涉及图片或字符串资源、新 board/resolution 接入或正式资源生成时使用；普通 C/C++ 布局和非资源缺陷修复不使用。"
---

# AEM Watch 正式资源流水线

本 Skill 是一次性的资源执行工作流：接收明确的操作和项目 JSON，校验环境，调用 WPS 或 UI Editor，执行 Post 后把结果交还主任务。它不重新搜索或解释 `AGENTS.md`；当前任务已经加载的用户要求和项目规则负责授权、选择 profile 及决定单次交付或批量收尾。

每次调用必须显式传入当前分支的项目 JSON。缺少配置、配置不能唯一定位工程或配置与实际文件不一致时停止；不得从 Skill 名、分支名、历史对话或其他工程推断 application、board、resolution、路径和功能开关。

## 输入契约

- 所有操作：`-ConfigPath <project-profile.json>`。
- 翻译、Pre、Post 和完整收尾：同时传入 `-ManifestPath <case.json>`。
- `Generate`、`FinalizeResources` 会打开桌面 UI Editor，必须在具备 Windows GUI 访问能力的执行环境中运行，并在启动前取得宿主要求的 GUI/沙箱外执行授权。若返回 `GUI_AUTOMATION_UNAVAILABLE`，停止在当前环境重试，改为请求授权后执行一次。

## 两条能力路径

| 路径 | 何时使用 | 环境门槛 |
|---|---|---|
| 图片/UI 资源 | 图片、资源 ID、`bt_watch.ui`、UI Editor 输出或资源状态变化 | `ResourceEnvironment`：项目文件、UI Editor、Python；WPS 仅提示 |
| 文本翻译 | 新增或修改字符串 key、翻译表或打包语言文本 | `TranslationEnvironment`：翻译表、WPS 安装路径、WPS COM |

只改 C/C++ 布局且正式资源输入没有变化时退出本 Skill。WPS 不可用只阻塞文本路径，不阻塞纯图片/UI 资源检查和生成；文本路径不得降级为其他库直接覆盖受保护 `.xls`。

## 选择参考

| 任务 | 必读 |
|---|---|
| 首次接入、配置变化或状态检查 | [configuration.md](references/configuration.md) |
| 文本资源 | [translation-path.md](references/translation-path.md)、[configuration.md](references/configuration.md)、[case-manifest.md](references/case-manifest.md) |
| 完整资源 | [resource-generation-path.md](references/resource-generation-path.md)、[configuration.md](references/configuration.md)、[case-manifest.md](references/case-manifest.md) |
| 新 board/resolution | [resolution-onboarding.md](references/resolution-onboarding.md)、[configuration.md](references/configuration.md) |

## 配置边界

- 所有脚本必须传入 `-ConfigPath <repo>/<project-profile.json>`；不得从 Skill 名称、分支名或历史任务推断档案。
- 项目配置从 [project-profile.template.json](assets/project-profile.template.json) 创建并随对应分支维护。
- 本机配置从 [local-config.template.json](assets/local-config.template.json) 创建；WPS、Python 等绝对路径只写入 `%USERPROFILE%/.codex/config/aem-watch-resource-pipeline.local.json`，不得提交。
- WPS COM 与当前 UI Editor 自动化只支持 Windows。环境不可用时给出缺失项和本机配置入口，不自动下载未知来源工具、不绕过许可证。
- application、board、resolution、语言、路径、输出和变化白名单只来自显式项目配置；项目 wrapper 负责选择与当前任务规则一致的配置。

## 稳定资源规则

- 正式图片来自 Figma 原始节点或项目认可的正式来源，不用截图、预览裁剪或 AI 重绘代替。
- `[CR]` 只用于设计或用户明确要求的强制换行；自动折行不转换为 `[CR]`。
- 新字符串覆盖项目配置和翻译表确认的全部打包语言；AI 翻译标记待人工审核，并保持格式占位符类型、数量和顺序。
- 正式资源输入没有变化时禁止生成。状态使用 SHA-256 与成功 Post 记录，不使用时间戳或对话记忆替代。
- WPS 写表属于文本资源路径中的 `TranslationApply`，不是自由表格编辑流程。
- 本 Skill 不提供编译、链接、烧录、OTA 或真机入口；这些操作由项目规则和用户当前任务另行授权。

## 统一脚本入口

从 `scripts/invoke-pipeline.ps1` 调用，并始终传入 `-ConfigPath`：

- `ResourceEnvironment`：只读检查图片/UI 资源路径需要的项目文件、UI Editor 和 Python；WPS 缺失仅提示。
- `TranslationEnvironment`：只读检查翻译表、WPS 路径和 COM 条件；失败时停止文本步骤并请求补充本机配置。
- `ResourcePrepare`：执行 `ResourceEnvironment` 和资源 `Pre`。
- `TranslationPrepare`：执行 `TranslationEnvironment` 和翻译 dry-run。
- `TranslationDryRun`：验证 manifest 与翻译写入计划，不修改表格。
- `TranslationApply`：备份后通过 WPS COM 写入受保护翻译表并重新验证。
- `ResourceStatus`：比较正式输入、输出与上次成功 Post，不启动 UI Editor。
- `Generate`：在已授权的 GUI 环境中只执行事务化资源生成，不记录最终状态。
- `FinalizeResources`：在已授权的 GUI 环境中执行资源环境检查、按需生成、恢复项目配置声明的手工声明、Post 和成功状态记录。
- `ResourcePre` / `Post`：分别执行生成前和生成后检查。

## 完成说明

文本、完整资源或新档案任务读取 [final-report.md](references/final-report.md)。只报告实际载入的配置、修改的正式输入、WPS/UI Editor 是否运行、实际输出和已执行检查；未执行的生成、编译、Figma、视觉或真机验证必须明确说明。
