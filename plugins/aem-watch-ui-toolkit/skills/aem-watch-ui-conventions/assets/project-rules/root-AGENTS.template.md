# {{PROJECT_NAME}} 工程协作规则

## 工程边界

- 唯一可写目标工程：`{{TARGET_ROOT}}`。
- 只读参考工程：`{{REFERENCE_ROOT_OR_NONE}}`。
- 写文件、启动外部工具或生成资源前，核对当前目录、Git 根和目标绝对路径。
- 保留用户已有修改，不处理与当前任务无关的差异。

## 产品档案

- 应用：`{{APPLICATION}}`。
- 功能基线：`{{BASE_BOARD_AND_RESOLUTION}}`。
- 目标产品：`{{TARGET_BOARD_AND_RESOLUTION}}`。
- 正式资源输入：`{{RESOURCE_INPUTS}}`。
- 正式资源输出：`{{RESOURCE_OUTPUTS}}`。

## 权限

- 资源输入变化后的生成策略：`{{RESOURCE_GENERATION_POLICY}}`。
- 编译策略：`{{BUILD_POLICY}}`。
- 未经用户明确要求，不烧录、打包或执行真机命令。

## 规则与 Skill

- 普通 AEM Watch UI 实现使用 `$aem-watch-ui-conventions`。
- Figma 和正式资源任务使用 `{{PROJECT_FIGMA_SKILL}}`；资源脚本配置为 `{{PIPELINE_CONFIG}}`。
- 目标目录存在更近的 `AGENTS.md` 时，下级差异优先。
