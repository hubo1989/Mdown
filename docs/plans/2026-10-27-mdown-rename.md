# Mdown 全面更名 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use executing-plans to implement this plan task-by-task.

**Goal:** 将仓库内现有产品、工程、模块、CLI、界面和维护文档统一为 Mdown，并保持现有笔记与设置可访问。

**Architecture:** Xcode target ID 和源文件注册关系保持原样，只同步更改工程路径、Scheme、模块及产品名称。已存储的 Bundle ID、iCloud container、xattr 和用户数据目录属于兼容协议，保留明确的 legacy 读取；新生成的链接与用户可见文本使用 Mdown。原作者版权与真实外部资源地址按来源保留。

**Tech Stack:** Swift 6、AppKit、SwiftUI、WKWebView、Xcode、Bash、Ruby。

---

### Task 1: 工程及内部名称

- 将 `MiaoYan.xcodeproj`、`MiaoYanMobile/`、`MiaoYanTests/`、entitlements、Scheme、移动端入口同步改为 Mdown 系列名称。
- 更新 `project.pbxproj`、`Package.swift`、storyboard/XIB customModule、测试 import 和 fixture 路径。
- 同步 Swift / JS / CSS 内部名称与桥接协议；不修改 vendored 库或测试 fixture 内容字节。
- 验证：`xcodebuild -list -project Mdown.xcodeproj`，构建及 XCTest 覆盖目标注册和桥接契约。

### Task 2: 用户文案与兼容

- 更新 `Resources/Localization/` 与移动端文案、菜单、关于窗口、预览标题。
- 新链接生成 `mdown://`，旧 `miaoyan://` 在至少一个兼容版本内继续识别。
- 保留现有 Bundle ID、iCloud 标识、xattr 和存量版本历史、固定笔记、缓存等数据存储位置；明确说明保留原因。
- 对新增兼容行为增加有效回归验证；不通过改名迁移或删除用户目录。

### Task 3: CLI、脚本与文档

- `scripts/mdown` 为主入口，`scripts/miaoyan` 保留转发兼容。
- 新的 `MDOWN_*` 环境变量优先，继续接受旧 `MIAOYAN_*` 参数。
- 构建脚本直接使用 `Mdown.app` 和 `Mdown` 可执行文件，移除打包后重命名及旧 app symlink。
- README、Agent Skill、CI、发布辅助工具的当前项目链接指向本仓库，原始项目作为致谢保留；不宣称 Mdown 已在上游 App Store / Homebrew 发布。
- 仅修改 `.agents/skills/` canonical 文件，再运行 `bash scripts/sync-agent-skills.sh --write` 和 `--check`。

### Task 4: 验证与交付

1. 检查所有残留旧名称，限定为有说明的兼容值、原作者署名或真实外部资源地址。
2. Shell/Ruby/JS 语法检查、plist 检查及 release notes 渲染 smoke。
3. `swiftlint lint --strict`、`swift-format lint --recursive . --strict`。
4. `xcodebuild -project Mdown.xcodeproj -scheme Mdown -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`。
5. `xcodebuild test -project Mdown.xcodeproj -scheme Mdown -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`。
6. `xcodebuild -project Mdown.xcodeproj -scheme MdownMobile -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`。
7. 启动构建产物，检查 macOS 菜单/关于/偏好设置和 iOS Simulator 首屏/设置中的名称。
8. 审查最终差异，报告完成情况、实际验证结果及外部发布限制。当前任务不提交、不推送、不发布。

## 全新应用身份迁移补充（用户后续明确要求）

新身份为 `com.mdown.app`、`com.mdown.app.tests` 和 `iCloud.com.mdown.app`。优先复用 Apple 现有后台配置；Developer / App Store Connect 后台注册与签名授权是前置条件，不能由本地 entitlements 伪造。

### 保留与迁移

- macOS 启动在 Storage 初始化之前迁移 `com.tw93.miaoyan` / `com.tw93.MiaoYan` 两套偏好到标准域；新域已有值不覆盖，迁移 marker 只在成功写入后设置。共享项目 URL 单独从 `group.miaoyan-manager` 补齐。
- macOS 历史版本读取/保存新目录，首次访问时把原目录复制过来；不修改或删除旧目录。文档与 Settings 提供旧 iCloud 库导入口；只有用户明确选择旧库时才以旧容器启动，避免无权限探测或把书签改指向无授权容器。
- iOS 在 `@AppStorage` 首次访问之前，将 `MiaoYanMobile.RootBookmark*` / `FontSize` / `FontFamily` 复制到 `MdownMobile.*`。旧 iCloud 书签仍保留，在旧容器权限可用时读取；不可用时保留书签并展示恢复提示，不静默切到空的新库。
- 笔记库发生路径变化时，把原路径的 Project/ProjectSettings 配置、选中路径、滚动位置与 NoteVersionManager 关联到新路径，其他偏好原样保留。迁移采用原库到新库的非破坏复制；完成后切换书签和路径，旧库永不自动搬空。
- xattr 的新旧键在 macOS/iOS 使用相同顺序双读；写入新旧两个键，unpin / cursor 更新同步，`.removedFromTrash` 和 `.pins.shared` 保留原协议。

### 验证

- 先写偏好与迁移失败用例，测试新值不被覆盖、失败不写完成标记、路径关联可恢复、xattr 双读双写。
- macOS/iOS Debug build 与全部 XCTest 通过后，使用独立模拟器设备验证从旧容器升级，不从真实用户数据启动或删除其内容。
- Developer 后台与签名能力确认后再进行真机/Archive/iCloud 同步验证；本地构建通过不视为新 iCloud 能力已授权。
