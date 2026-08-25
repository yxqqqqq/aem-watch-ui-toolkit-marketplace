# AEM Watch 项目档案

`config/defaults.json` 只定义配置结构、跨项目路径模板和安全策略，不包含可执行的产品档案。实际配置是结构默认、本机配置、项目配置和显式参数合并后的结果；不要从 Skill 名称推断当前 board 或 resolution，也不要在说明文件和脚本中复制项目路径。

## 配置字段

| 字段 | 用途 |
|---|---|
| `project.application` | 应用和路径占位符 |
| `project.board` | 固件板型和正式资源目录 |
| `project.resolution` | UI 资源规格目录 |
| `project.rootMarkers` | 自动发现项目根目录 |
| `paths.resourceRoot` | UI 资源根目录 |
| `paths.uiProject` | UI Editor 工程 |
| `paths.translationTable` | 受保护多语言翻译表 |
| `paths.includeHeader` | 生成资源声明头文件 |
| `paths.stringMap` | 生成字符串映射 |
| `paths.boardResourceRoot` | 正式板级资源目录 |
| `paths.uiEditor` | UI Editor 可执行文件 |

路径支持 `{application}`、`{board}` 和 `{resolution}` 占位符。

## 翻译与生成

- `translation.languageColumns` 保存翻译表语言列；实际打包语言由调用方在显式项目配置中声明，并与翻译表语言代码行核对，不在通用流程中固定。
- `generation.generatedFiles` 定义 Post 阶段必须存在且非空的文件。
- `generation.manualDeclarations` 定义 UI Editor 生成后必须保留或恢复的手工声明。
- `generation.preserveGeneratedSuffixes` 定义 UI Editor 只负责重写前缀、既有尾部必须从事务快照保留的生成文件；marker 必须是项目已验证的唯一文本。
- 编译和设备命令不属于资源 Skill 配置；需要时由当前项目规则和用户任务另行确定。
