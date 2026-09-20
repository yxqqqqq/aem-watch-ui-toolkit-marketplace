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

正式翻译表保持原有 `.xls`/OLE2 格式。禁止转换成 `.xlsx`，也禁止用未验证的普通 XLS 库直接覆盖。

1. 运行 `TranslationPrepare -ManifestPath <case.json> -ConfigPath <project-config.json>`。
2. `translation.backend=auto` 时，标准 OLE/BIFF8 工作簿优先使用 Plugin 内置 POI 写入器；配置了 `protectedWrapperTokens` 的工作簿选择 WPS。项目确有兼容性要求时可显式使用 `poi` 或 `wps`，但 `poi` 不接受保护包装标记。
3. 解决全部环境和 dry-run 问题。POI 路径只需要可用 Java 运行时，依赖随 Plugin 固定分发；WPS 路径需要本机 `tools.wpsRoots` 和 COM，只有该路径需要 `-RegisterWps`。
4. 运行 `TranslationApply -ManifestPath <case.json> -ConfigPath <project-config.json>`。两种后端都必须先备份并重新打开验证键唯一性、打包语言和最终文本：
   - POI 先写同目录候选文件，验证目标值、根 CLSID 和全部非 `Workbook` OLE 流，再替换正式表；任何失败都不覆盖正式表。
   - WPS 通过 COM 保存，并验证配置声明的保护包装标记仍存在。
5. 翻译表变化属于正式资源输入变化，必须按 [resource-generation-path.md](resource-generation-path.md) 的事务要求生成和检查。

文本写入不授权编译；可以只完成翻译写入与资源收尾。
