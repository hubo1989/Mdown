<h4 align="right">English | <strong><a href="https://github.com/hubo1989/Mdown/blob/main/README_CN.md">简体中文</a></strong></h4>

<h1 align="center">Mdown</h1>

<p align="center">A lightweight, native, local-first Markdown editor</p>

## Features

- **Fantastic**: Local-first, no data collection, split editor & preview, wikilink backlinks, LaTeX, Mermaid
- **Beautiful**: Minimalist design, three-column layout, dark mode, macOS 26 glass, distraction-free
- **Fast**: Swift 6 native, better performance than Electron-based apps
- **Simple**: Lightweight, version history, keyboard shortcuts, auto-formatting

## Installation

Download Mdown from [Mdown Releases](https://github.com/hubo1989/Mdown/releases), or build from source using the [contribution guide](CONTRIBUTING.md).

After installing, create a `Mdown` folder in iCloud Drive, your desktop cloud-drive folder, or another location, then select it in Preferences (⌘,).

Mdown is derived from [MiaoYan](https://github.com/tw93/MiaoYan). The upstream App Store and Homebrew listings distribute the original project.

## Sync with Nutstore or Other Cloud Drives

Mdown is local-first and does not sign in to WebDAV or cloud-drive accounts. It reads and writes the Markdown folder you choose. iCloud Drive, Nutstore, Dropbox, or another cloud-drive client handles cross-device sync.

- **Mac**: Create a `Mdown` folder inside the local folder synced by the Nutstore desktop client, then point Mdown's storage location to it in Preferences.
- **iPhone**: Pick the same cloud-drive folder from the system Files app. If a provider does not expose a writable folder in Files, use iCloud Drive or make the folder available offline in that provider app before choosing it.
- **Folder check**: Mdown verifies read and write access before switching folders. If the folder is unavailable, the current storage path stays unchanged.

## CLI

Mdown provides a command-line interface for quick note operations.

```bash
# Install
curl -fsSL https://raw.githubusercontent.com/hubo1989/Mdown/main/scripts/install.sh | bash

# Usage
mdown open <title|path>    # Open note or folder
mdown new <title> [text]   # Create new note
mdown search <query>       # Search notes in terminal
mdown list [folder]        # List top-level folders, or markdown in folder
mdown cat <title|path>     # Print note content
mdown update               # Update CLI
```

The legacy `miao` / `miaoyan` commands and `MIAOYAN_PATH` remain supported; prefer `mdown` and `MDOWN_PATH` in new scripts.

## Flexible Editing Modes

Mdown supports three native editing modes to fit your workflow:

- **Pure Editing**: Clean, minimalist Markdown source editor without distraction.
- **Split Mode**: Edit and preview side by side with real-time preview and 60fps bidirectional scroll sync. Toggle instantly with `⌘\`.
- **WYSIWYG Mode**: Native direct-editing experience that hides markup delimiters while keeping pure, authoritative Markdown under the hood.

Configure your preferred default in **Preferences → Interface → Editor Mode**, or toggle between them seamlessly.

<img src="https://gw.alipayobjects.com/zos/k/eg/jV8Gra.png" width="100%" alt="Split Editor & Preview Mode" />

### High-Resolution Rendered Block Export

Right-click any rendered Mermaid diagram, PlantUML graph, or KaTeX math formula in the preview pane to export standalone, retina-crisp PNG (1×/2×/3×) or sanitized SVG vector images.

## Documentation

- [Markdown Syntax Guide](Resources/Initial/Mdown%20Markdown%20Syntax%20Guide.md) - Complete syntax reference with advanced features
- [PPT Presentation Mode](Resources/Initial/Mdown%20Slides.md) - Guide to creating presentations with `---` slide separators
- [Mdown Agent Skill](skills/mdown) - Teach your agent Mdown syntax, attachments, PPT patterns, and CLI workflows

Install the official skill with `npx skills add hubo1989/Mdown/skills/mdown -g`.

## Support

Star Mdown, report problems through [Issues](https://github.com/hubo1989/Mdown/issues), or contribute a pull request.

## Acknowledgments

- [tw93/MiaoYan](https://github.com/tw93/MiaoYan) - Original project; the MIT copyright notice is retained
- [glushchenko/fsnotes](https://github.com/glushchenko/fsnotes) - Initial project structure reference
- [stackotter/swift-cmark-gfm](https://github.com/stackotter/swift-cmark-gfm) - Swift Markdown parser

- [hakimel/reveal.js](https://github.com/hakimel/reveal.js) - PPT presentation framework
## License

MIT License - Feel free to use and contribute.
