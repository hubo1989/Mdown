# V4.2.0 Zinogre 🍝

1. 修复已删除笔记被延迟保存重新创建的问题，切换侧栏或重启后不会再次出现
2. 修复复杂 LaTeX 公式渲染，下标、绝对值和自适应括号现在可在预览与 PPT 中正确组合
3. 修复删除笔记后侧边栏可能横向偏移的问题，文件夹列表会始终贴齐窗口宽度
4. 改进 PDF 导出，Mermaid 图表不再重复渲染，标题也会沿用当前笔记字体
5. 修复 PPT 本地图片丢失，以及窗口置顶时偏好设置被遮挡的问题
6. 改进 HDR 照片在 Markdown 预览中的显示效果，画面不再异常过曝
7. 新增官方 Mdown Agent Skill，让 Agent 能按Mdown的语法、附件、PPT 与 CLI 规范处理笔记

---

1. Prevents deleted notes from being recreated by delayed saves after switching sections or restarting
2. Complex LaTeX formulas now render correctly in preview and PPT when subscripts, absolute values, and adaptive delimiters are combined
3. Sidebar folders remain horizontally aligned after deleting notes, reloading, or resizing the window
4. PDF exports no longer rerender Mermaid diagrams, and headings use the current note font
5. PPT keeps local images, and Preferences stays visible when windows are kept on top
6. HDR photos display with balanced tones instead of appearing overexposed in Markdown preview
7. New official Mdown Agent Skill teaches agents the app's Markdown, attachment, PPT, and CLI conventions
