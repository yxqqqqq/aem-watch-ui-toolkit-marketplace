# {{APPLICATION}} UI 项目规则

## 基线与目标

- 功能参考：`{{BASE_BOARD}}` + `{{BASE_RESOLUTION}}`。
- 视觉目标：`{{TARGET_BOARD}}` + `{{TARGET_RESOLUTION}}`。
- 当前任务是否需要兼容多个分辨率：`{{MULTI_RESOLUTION_POLICY}}`。
- 目标 Figma/截图来源：`{{DESIGN_SOURCE}}`。

## 资源档案

- UI 工程：`{{UI_PROJECT}}`。
- 图片输入：`{{IMAGE_ROOT}}`。
- 翻译输入：`{{TRANSLATION_TABLE}}`。
- 生成 C/H：`{{GENERATED_SOURCE_ROOT}}`。
- 板级输出：`{{BOARD_RESOURCE_ROOT}}`。
- UI Editor：`{{UI_EDITOR}}`。
- 项目流水线覆盖配置：`{{PIPELINE_CONFIG}}`。

## 项目差异

- `{{PROJECT_SPECIFIC_LAYOUT_RULES}}`
- `{{PROJECT_SPECIFIC_RESOURCE_GATES}}`
- `{{PROJECT_SPECIFIC_FEATURE_BOUNDARIES}}`

普通页面实现遵守 `$aem-watch-ui-conventions`，本文件只写当前项目覆盖。正式资源流程遵守项目 Figma/资源 Skill，不在本文件复制脚本步骤。
