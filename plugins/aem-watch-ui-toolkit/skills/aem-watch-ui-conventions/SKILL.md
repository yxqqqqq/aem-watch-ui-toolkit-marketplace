---
name: aem-watch-ui-conventions
description: "实现、迁移、替换或审查 ATS308x/AEM Watch 的 LVGL 应用界面与公共控件时使用，包括普通 C 布局、生命周期、刷新、失败处理、文本、图片和控件复用；也用于把旧项目 UI 规则筛选成新项目模板。资源生成、翻译表和 UI Editor 事务由项目 Figma/资源 Skill 处理，非 UI 功能任务不使用。"
---

# AEM Watch UI 通用约定

当前任务已经加载的用户要求和项目规则继续生效；本 Skill 不重新搜索或解释 `AGENTS.md`，只提供跨项目可复用的界面经验，不提供 board、resolution、绝对路径、资源档案或功能开关等项目事实。

## 选择所需参考

- 修改或审查应用页面时，读取 [references/ui-implementation.md](references/ui-implementation.md)。
- 调用、整理、扩展或选择 `thirdparty/lib/aem` 公共控件时，再读取 [references/public-widgets.md](references/public-widgets.md)；页面需要读取或覆盖其内部子控件、默认资源或事件时必须读取。
- 新项目、换分支或从旧工程迁移规则时，读取 [references/project-onboarding.md](references/project-onboarding.md)，并按需使用 `assets/project-rules/` 模板。
- 涉及 Figma 正式图片、翻译、`.ui` 或 UI Editor 时，本 Skill 继续约束 UI 判断，同时叠加项目指定的 Figma/资源 Skill；不要在这里复制资源流水线。

不要预先读取所有参考文件。只加载当前路径需要的内容。

## 稳定判断顺序

信息冲突时按以下顺序处理：

1. 用户对当前任务的明确要求。
2. 当前项目现有功能逻辑、数据接口、事件、生命周期和项目规则。
3. 用户确认的状态说明、截图或真机结果。
4. Figma 中可见的布局与视觉事实。
5. 当前项目同类且已验证的页面或公共控件。
6. 旧项目经验和自行推断。

Figma 默认是视觉依据，不自动授权删除、启用或改变功能。旧项目只提供候选经验；迁移前必须在新项目验证 API、资源、交互和构建事实。

## 权限边界

- 普通 UI 修改不自动授权公共架构重构、资源生成、翻译写入、编译或设备操作。
- 正式资源输入是否变化由资源 Skill 和项目规则判断；只改 C/C++ 时不得顺带生成资源。
- 视觉适配默认保留事件类型、页面跳转、数据读写、定时器、消息、状态刷新和释放流程。

## 规则维护

用户反馈具有跨页面复用价值时，更新本 Skill 中已有规则；只属于当前仓库、模块或页面的事实写入最近的 `AGENTS.md`。不要把一个具体故障的补丁描述直接提升为绝对通用规则，先提炼它改变决策的条件和例外。
