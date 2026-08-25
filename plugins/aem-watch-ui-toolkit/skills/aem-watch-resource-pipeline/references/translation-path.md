# 文本资源路径

适用于新增或修改翻译、字符串键或当前打包语言文本，但不修改图片。

## 准备

1. 读取 [configuration.md](configuration.md)，合并默认、本机和项目覆盖配置。
2. 按 [case-manifest.md](case-manifest.md) 创建工作区外的临时 UTF-8 manifest。
3. 核对翻译表语言代码行与显式项目配置中的全部当前打包语言；不得从示例 manifest、分支名或历史项目照抄。
4. 新字符串覆盖全部 `active_languages`。Figma 只提供部分语言时，只有用户允许 AI 翻译的语言才主动补齐，并在报告中标记待人工审核。
5. 只有 Figma 明确存在手动换行或用户明确要求时，才允许 `[CR]`、CR 或 LF。
6. 保持 printf 占位符的类型、顺序和数量一致。

每个字符串必须确保以下三项各存在一次：

1. `multiLang_translate_table.xls` 中的完整 key。
2. `bt_watch.ui` 中 `strid` 与 UI key 一致的 `string_resource`。
3. 一个全局 `<string value="UI key" />` 索引。

UI 工程采用截断 key 时沿用既有结果，不新增第二个映射。

## 写入和生成

翻译表受 E-SafeNet 保护。禁止转换成 `.xlsx` 或使用普通 XLS 库覆盖。

1. 运行 `TranslationPrepare -ManifestPath <case.json> -ConfigPath <project-config.json> -RegisterWps`。
2. 解决全部环境和 dry-run 问题。找不到 WPS 路径时停止文本步骤，请用户从 `assets/local-config.template.json` 补充本机配置；不要改用普通 XLS 库覆盖受保护文件。
3. 运行 `TranslationApply -ManifestPath <case.json> -ConfigPath <project-config.json> -RegisterWps`；脚本必须备份、通过 WPS COM 保存，并重新打开验证保护包装、键唯一性、打包语言和换行。
4. 翻译表变化属于正式资源输入变化，必须按 [resource-generation-path.md](resource-generation-path.md) 的事务要求生成和检查。

文本写入不授权编译；可以只完成翻译写入与资源收尾。
