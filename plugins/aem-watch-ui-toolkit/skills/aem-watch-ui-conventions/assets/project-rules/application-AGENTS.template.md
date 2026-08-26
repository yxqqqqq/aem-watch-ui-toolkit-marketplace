# 应用页面项目覆盖

本文件只记录 `{{APPLICATION_SOURCE_ROOT}}` 在当前分支相对于 `$aem-watch-ui-conventions` 的差异。

## 已验证能力

- 可用页面根控件：`{{PAGE_CONTAINERS}}`。
- 可用列表/滚轮控件：`{{LIST_AND_ROLLER_WIDGETS}}`。
- 可用文本与标题控件：`{{TEXT_AND_TITLE_WIDGETS}}`。
- `lv_obj_align_to(obj,NULL,...)` 行为：`{{ALIGN_TO_NULL_BEHAVIOR}}`。

## 当前字体档案

- 生效 board、resolution 和条件编译入口：`{{ACTIVE_FONT_PROFILE}}`。
- 公共字体 getter 到实际声明字号的映射：`{{FONT_GETTER_SIZE_MAPPING}}`。
- 参数化或运行时字体接口的验证状态：`{{DYNAMIC_FONT_API_STATUS}}`。

## 当前项目参考页面

- 标准列表：`{{STANDARD_LIST_REFERENCE}}`。
- 单列滚轮：`{{SINGLE_ROLLER_REFERENCE}}`。
- 多列滚轮：`{{MULTI_ROLLER_REFERENCE}}`。
- 信息/长文本页面：`{{INFO_PAGE_REFERENCE}}`。

## 当前项目例外

- `{{APPLICATION_SPECIFIC_EXCEPTIONS}}`

不要从旧工程复制当前分支不存在的控件、接口、字体映射、滚动条实现或固定尺寸。
