# 配置分层

文本资源、完整资源、新档案接入或显式配置变更时读取。所有正式资源操作都需要项目配置，不存在内置产品默认档案。

使用 JSON，避免增加 YAML 运行依赖。加载顺序从低到高：

1. Skill 内置 `config/defaults.json`：只提供配置结构、跨项目路径模板和安全默认策略。
2. 本机配置 `%USERPROFILE%/.codex/config/aem-watch-resource-pipeline.local.json`。
3. 命令行 `-ConfigPath` 指定的项目配置。
4. 脚本显式命令行参数。

所有脚本必须显式传入 `-ConfigPath`。从 [../assets/project-profile.template.json](../assets/project-profile.template.json) 建立项目配置；不要修改 Skill 默认值来切换项目。

## 必填项目事实

项目配置必须提供并通过检查：

- `project.application`、`project.board`、`project.resolution` 和至少一个 `project.rootMarkers`。
- 实际存在的 UI 工程、翻译表、资源目录和 UI Editor 路径。
- 非空且覆盖全部正式输出的 `generation.generatedFiles`。
- 非空且只允许本流程预期变化的 `generation.allowedChangePatterns`。
- 当前项目需要保留的 `generation.manualDeclarations`；不需要时显式使用空数组。
- UI Editor 会覆盖、但项目必须保留的生成文件尾部使用 `generation.preserveGeneratedSuffixes` 声明文件和唯一 marker；不需要时使用空数组。
- 当前翻译表布局与打包语言；示例语言不能替代项目验证。

所有项目路径相对于自动发现的 Git 工作区根，支持 `{application}`、`{board}`、`{resolution}` 占位符。调用方使用当前任务已经生效的项目规则选择 profile；流水线只校验 profile 与板级配置、资源 CMake、UI 工程和实际路径的一致性，不自行搜索规则或切换 profile。

## 执行策略

```json
{
  "execution": {
    "mode": "auto",
    "resourceGenerationPolicy": "project",
    "regenerateResourcesOnlyWhenChanged": true
  }
}
```

- `mode=auto`：根据正式输入变化选择文本或完整资源路径。
- `resourceGenerationPolicy=project`：调用方在进入 Skill 前已经根据项目规则决定单次交付或批量收尾，通用 Skill 不重新判断批次状态。
- `regenerateResourcesOnlyWhenChanged=true`：使用 SHA-256 判断翻译表、UI 工程和引用图片是否变化；只改 C/C++ 时禁止生成资源。

本 Skill 没有编译、链接、烧录、OTA 或设备入口。资源配置不能扩大当前任务已经取得的权限。

## 本机配置

本机配置只保存绝对工具路径和机器差异，不保存密码、Token、Figma 凭据或项目事实：

首次使用时从 [../assets/local-config.template.json](../assets/local-config.template.json) 复制，不要提交填写后的本机文件。

```json
{
  "schemaVersion": 1,
  "tools": {
    "pythonExecutable": "C:/Python313/python.exe",
    "wpsRoots": ["D:/wps/WPS Office"]
  }
}
```

Python 未配置时，脚本依次尝试 Codex 内置 Python、PATH `python.exe` 和 `py.exe -3`。资源脚本采用 JSON 和 Python 标准库，不需要 PyYAML。

WPS COM 与当前 UI Editor 自动化是 Windows 专用路径。`ResourceEnvironment` 和 `TranslationEnvironment` 分别检查两条能力：WPS 缺失只阻塞文本步骤，UI Editor 或 Python 缺失只阻塞资源生成。不自动下载工具、不接受未知来源的安装包，也不通过其他表格库直接覆盖受保护工作簿。

## 资源事务

- `generation.stateRoot` 相对于 `%LOCALAPPDATA%`，只在 Post 成功后记录 UI 工程、翻译表、引用图片和正式输出的 SHA-256。状态按项目根、application、board 和 resolution 隔离。
- `generation.snapshotRoots` 在启动 UI Editor 前完整备份到工作区外。失败时恢复原文件并删除本次新增文件；成功时只保留 `allowedChangePatterns` 内的变化，并恢复临时文件和配置指定的输入文件。
- `generation.normalizeChangedTextFiles` 对内容未变、仅首尾空白不同的行恢复生成前格式；对真正新增或改值的行清理行尾空白及“空格后跟 Tab”的缩进，不批量重写历史格式。
- `generation.preserveGeneratedSuffixes` 从事务快照提取 marker 开始的既有尾部，与 UI Editor 新生成的前缀合并；marker 在快照中缺失、目标文件缺失或不唯一时生成失败并回滚。
- `generation.generatedFiles` 必须覆盖 `.res`、`.sty`、当前打包语言、文本中间文件及生成 C/H；`tmp.csv` 不属于正式输出。
- JPEG 临时文件只能根据 UI 工程真实引用关系识别，不使用宽泛目录通配符。
- `generation.editorCommands` 与 UI Editor 版本绑定；工具升级后必须重新验证菜单 ID。

## 项目配置归属

项目配置随对应仓库或分支维护，只写项目事实和相对路径。分支切换时由 Git 切换配置，不手工把一份配置在多个 board 间反复改写。同一分支同时支持多个档案时，使用独立命名的 profile，并由最近的项目规则明确选择。

## 单次任务 manifest

manifest 只保存本次 Figma 节点、资源、文本、目标代码和已获授权的设备命令。application、board、resolution、稳定路径和工具配置不写入单次 manifest。
