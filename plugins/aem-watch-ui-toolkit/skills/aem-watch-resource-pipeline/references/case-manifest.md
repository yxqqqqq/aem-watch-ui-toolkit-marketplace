# Case manifest

每个正式资源任务创建一个工作区外的临时 UTF-8 JSON：

```json
{
  "name": "task-name",
  "figma_nodes": [
    {
      "url": "https://www.figma.com/design/FILE_KEY/FILE_NAME?node-id=123-456",
      "node_id": "123:456",
      "state": "default"
    }
  ],
  "target_files": [
    "application/aem_watch/src/application/module/target_ui.c"
  ],
  "active_languages": ["zhC", "enG"],
  "pictures": [
    {
      "resource_name": "pic_semantic_name",
      "ui_path": ".\\module\\image.png",
      "symbol": "IMG_SCENE_MODULE_PIC_SEMANTIC_NAME",
      "width": 100,
      "height": 100
    }
  ],
  "strings": [
    {
      "table_key": "key_sample_title",
      "ui_key": "key_sample_title",
      "resource_name": "str_sample_title",
      "symbol": "ID_KEY_SAMPLE_TITLE",
      "allow_forced_break": false,
      "translations": {
        "zhC": "示例标题",
        "enG": "Sample title"
      }
    }
  ]
}
```

## 规则

- project、board、resolution 和工具路径保存在 pipeline 配置中，不写入单次 manifest。
- `table_key` 是翻译表第一列完整 key；`ui_key` 是 `bt_watch.ui` 和生成映射使用的 key，可能因工具限制被截断。
- `resource_name` 是本地 `picture_resource` 或 `string_resource` 名称；`symbol` 是生成的 C 图片符号或字符串枚举。
- `ui_path` 相对于 UI 工程，沿用目标项目现有的 `./` 或 `.\` 约定。
- `active_languages` 必须与翻译表语言代码行和项目配置确认的实际打包语言一致；不得照抄示例，必须填写自己的全部打包语言。
- 每个新增字符串覆盖全部 `active_languages`。AI 生成的翻译在完成报告中标记待人工审核；不熟悉且未获授权的语言不要自行填充。
- `allow_forced_break` 只有设计或用户明确要求强制换行时为 `true`。
- `%d`、`%02d`、`%s`、`%%` 等格式占位符在所有打包语言中保持类型、数量和顺序一致。
