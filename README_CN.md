<h4 align="right"><strong><a href="https://github.com/hubo1989/Mdown">English</a></strong> | 简体中文</h4>

<h1 align="center">Mdown</h1>

<p align="center">轻量、原生、本地优先的 Markdown 编辑器</p>

## 特点

- **妙**：纯本地使用、不收集任何数据、语法高亮、分栏编辑预览、Wikilink 双向链接、PPT 演示、LaTeX、Mermaid 图表
- **美**：极简设计风格、三栏模式、深色模式、macOS 26 玻璃质感、专注写作
- **快**：Swift 6 原生开发、相比 Web 套壳性能体验更好
- **简**：轻量纯粹、版本历史、众多快捷键、自动排版

## 安装使用

从 [Mdown Releases](https://github.com/hubo1989/Mdown/releases) 下载 Mdown，或按 [贡献指南](CONTRIBUTING.md) 从源码构建。

安装后在 iCloud 云盘、坚果云桌面同步目录或其他位置创建 `Mdown` 文件夹，打开设置（⌘,）指定存储位置。

Mdown 由 [MiaoYan](https://github.com/tw93/MiaoYan) 衍生；上游的 App Store 和 Homebrew 安装入口提供的是原项目。

## 用坚果云或其他云盘同步 Mdown

Mdown 保持本地优先,不会登录 WebDAV 或网盘账号。它只读写你指定的 Markdown 文件夹,跨设备同步由 iCloud Drive、坚果云、Dropbox 等云盘客户端负责。

- **Mac**: 在坚果云桌面客户端的同步目录中创建 `Mdown` 文件夹,然后在 Mdown 设置中把存储位置指向它。
- **iPhone**: 在系统“文件”App 中选择同一个云盘文件夹。若某个云盘 App 没有暴露可写文件夹,建议使用 iCloud Drive,或先在云盘 App 中让该文件夹可离线访问后再选择。
- **目录检查**: Mdown 会在切换目录前确认文件夹可读取、可写入。不可用时不会保存新路径,也不会把问题误报成 Mdown 自己的云同步失败。

## 命令行工具

Mdown 提供命令行工具，方便在终端中快速操作笔记。

```bash
# 安装
curl -fsSL https://raw.githubusercontent.com/hubo1989/Mdown/main/scripts/install.sh | bash

# 使用
mdown open <标题|路径>    # 打开笔记或文件夹
mdown new <标题> [内容]   # 创建新笔记
mdown search <关键词>     # 在终端搜索笔记
mdown list [folder]      # 列在一级目录，或列出指定目录下的 Markdown
mdown cat <标题|路径>     # 输出笔记内容
mdown update             # 更新 CLI
```

旧命令 `miao` / `miaoyan` 和 `MIAOYAN_PATH` 继续兼容；新脚本优先使用 `mdown` 和 `MDOWN_PATH`。

## 多样化编辑模式

Mdown 提供三种原生编辑模式，满足不同写作偏好：

- **纯编辑模式**：极简专注的 Markdown 源码编辑体验。
- **分栏模式**：编辑区和预览区并排显示，支持 60fps 双向滚动同步，实时呈现排版效果。按 `⌘\` 快速切换。
- **所见即所得模式 (WYSIWYG)**：原生直接编辑排版视图，隐藏 Markdown 标记符号的同时始终以纯净 Markdown 为唯一权威真相。

可在 **设置 → 界面 → 编辑模式** 中自由选择默认模式，并在使用中平滑往返。

<img src="https://gw.alipayobjects.com/zos/k/eg/jV8Gra.png" width="100%" alt="分栏编辑预览模式" />

### 渲染块独立高清导出

在预览区右键点击任意 Mermaid 流程图、PlantUML 图表或 KaTeX 数学公式，即可单独导出为 1×/2×/3× 高清 PNG 位图或经过安全净化的独立 SVG 矢量图。

## 使用指南

- [介绍 Mdown](Resources/Initial/介绍%20Mdown.md) - 完整使用指南,包含快捷键等
- [Markdown 语法指南](Resources/Initial/Mdown%20Markdown%20语法指南.md) - 完整语法演示,数学公式、图表等
- [PPT 演示模式](Resources/Initial/Mdown%20PPT.md) - 使用 `---` 分隔幻灯片的演示指南
- [Mdown Agent Skill](skills/mdown) - 让 Agent 掌握 Mdown 语法、附件、PPT 与 CLI 使用方式

运行 `npx skills add hubo1989/Mdown/skills/mdown -g` 安装官方 Skill。

## 支持

欢迎给 Mdown 一个 Star，通过 [Issues](https://github.com/hubo1989/Mdown/issues) 反馈问题，或提交 PR 改进项目。

## 致谢

- [tw93/MiaoYan](https://github.com/tw93/MiaoYan) - 原始项目，保留 Tw93 的 MIT 版权声明
- [glushchenko/fsnotes](https://github.com/glushchenko/fsnotes) - 项目初始结构参考
- [stackotter/swift-cmark-gfm](https://github.com/stackotter/swift-cmark-gfm) - Swift Markdown 解析器

- [仓耳字库](https://tsanger.cn/product) - 仓耳今楷字体(默认字体)
- [hakimel/reveal.js](https://github.com/hakimel/reveal.js) - PPT 演示框架
## 协议

MIT License - 欢迎自由使用与贡献
