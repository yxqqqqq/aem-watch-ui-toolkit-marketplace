# 完整资源路径

适用于新增或修改图片、图片路径、资源 ID、`bt_watch.ui`，以及文本资源写入后的正式资源生成。

## 准备输入

1. 读取 [configuration.md](configuration.md)，合并配置并确认项目根、application、board、resolution、UI 工程和正式输出目录。
2. 按 [case-manifest.md](case-manifest.md) 创建工作区外的临时 manifest。
3. 新增资源前搜索可复用的图片和字符串符号。
4. 使用当前环境可用、项目认可的 Figma 能力从原始节点导出正式图片；禁止用截图、裁剪预览或 AI 重绘代替。无法导出原始节点时报告阻塞，不伪造正式资源。
5. 同时新增或修改字符串时，先读取并执行 [translation-path.md](translation-path.md)，再进入生成步骤。

每张图片必须同时添加一个带相对 layer 路径的 `picture_resource` 和一个全局 `<picture value="相对路径" />` 搜索路径。每个字符串必须同时满足翻译表完整 key、`string_resource` 和全局 `<string>` 索引。

## Pre 检查

运行：

```powershell
powershell -ExecutionPolicy Bypass -File "<skill>/scripts/invoke-pipeline.ps1" `
  -Action ResourcePrepare -ManifestPath "<case.json>" -ConfigPath "<project-config.json>"
```

`-ConfigPath` 不得省略。`ResourcePrepare` 依次执行资源环境检查和资源 Pre。纯图片/UI 任务不要求 WPS；同时修改文本时，先单独完成 `TranslationPrepare` 和 `TranslationApply`。

## 事务化生成

正常收尾运行 `FinalizeResources -ManifestPath <case.json> -ConfigPath <project-config.json>`。它先读取资源状态，仅在输入或输出变化时启动 UI Editor，然后恢复项目配置 `generation.manualDeclarations` 中明确列出的声明、执行 Post 并记录状态。迭代期间只运行 `ResourceStatus`；显式强制重建时增加 `-ForceResourceGeneration`。

`Generate` 和 `FinalizeResources` 会启动桌面程序并枚举原生窗口。在 Codex 的受限执行环境中，调用这两个操作时必须请求 GUI/沙箱外执行授权；只读检查、Pre、Post 和 `ResourceStatus` 不需要因此提升权限。脚本会在创建快照和启动 UI Editor 前执行窗口枚举预检：出现 `GUI_AUTOMATION_UNAVAILABLE` 时不得在同一沙箱内反复重试，应取得授权后重新执行一次。

低层 `Generate` 只生成、不执行 Post、不记录新状态。生成器必须：

- 在工作区外备份配置的资源目录并记录 SHA-256。
- 使用独立 UI Editor 打开配置的工程并执行配置的高质量生成模式。
- 识别覆盖、进度、成功和错误窗口；未知模态窗口视为失败。
- 等待正式生成文件存在、非空且稳定。
- 限制变化只能落在配置白名单。
- 只把 UI 工程已引用 JPEG 对应、但自身未被引用的 `_tmp.jpg/.jpeg` 识别为编辑器中间文件；已有文件按哈希恢复，新建文件删除并报告。
- 成功后恢复 UI 工程原文和 `tmp.csv` 等非正式输出；失败后逐文件回滚并验证哈希。
- 对项目配置 `preserveGeneratedSuffixes` 指定的文件，用本次事务快照中 marker 开始的尾部替换 UI Editor 输出的对应尾部；marker 缺失时回滚，不拼接猜测内容。

不要直接使用 `resBuildApp.exe` 覆盖正式资源。正常流程不使用 `-AllowMissingGeneratedFiles`；只有恢复已确认缺失的历史生成物时才临时启用。允许重复生成结果逐字节不变时使用 `-AllowUnchangedResources`。

## Post 与授权边界

- 查看是否待生成：`ResourceStatus -ConfigPath <project-config.json>`。
- 正常资源收尾：`FinalizeResources -ManifestPath <case.json> -ConfigPath <project-config.json>`。
- 仅生成：`Generate -ConfigPath <project-config.json>`；不记录 Post 状态。
- 仅生成后检查：`Post -ManifestPath <case.json> -ConfigPath <project-config.json> -RepairManualDeclarations`。
- 本 Skill 不提供构建入口；资源任务不会触发编译。

Post 必须确认正式文件非空、C 符号一致，并保留配置声明的手工内容。资源生成成功不代表视觉、编译或设备验证完成。
