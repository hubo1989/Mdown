# V0.0.101 Nergigante 🎉

1. 项目全面更名为 Mdown：Xcode 工程、Target、Scheme、CLI、Agent Skills 与全部界面文案统一为 Mdown
2. 应用身份迁移至 com.mdown.app、iCloud.com.mdown.app 与 group.mdown-manager，新旧偏好与笔记数据非破坏自动迁移
3. 修复 WYSIWYG 模式下键盘输入被搜索框拦截的问题，编辑器现在可以正常打字
4. 新增 OpenCodeReview AI 自动代码审查工作流，PR 提交后自动触发中文审查
5. CLI 新增 mdown 主命令，保留 miao/miaoyan 兼容别名与 MIAOYAN_PATH 环境变量回退
6. 版本历史目录、置顶标记、光标位置与垃圾桶标记全面支持新旧双读双写，升级后不丢数据

---

1. Complete rebrand to Mdown: Xcode project, targets, schemes, CLI, Agent Skills, and all UI strings unified under the Mdown name
2. App identity migrated to com.mdown.app, iCloud.com.mdown.app, and group.mdown-manager with non-destructive automatic migration of legacy preferences and note data
3. Fixed WYSIWYG mode keyboard input being intercepted by the search field; the editor now accepts typed input correctly
4. Added OpenCodeReview AI code review workflow that automatically triggers Chinese-language reviews on pull requests
5. CLI gains the mdown primary command with miao/miaoyan compatibility aliases and MIAOYAN_PATH environment variable fallback
6. Version history directories, pin markers, cursor positions, and trash markers support dual read/write for both new and legacy formats, preserving data across upgrades
