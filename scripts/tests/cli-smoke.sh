#!/usr/bin/env bash
# 使用临时笔记和命令替身验证 CLI；不读取真实偏好，不安装或访问网络。
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cli="${1:-$repo_root/scripts/mdown}"
task_dir="$(mktemp -d)"
trap 'rm -rf "$task_dir"' EXIT
mkdir -p "$task_dir/library" "$task_dir/legacy" "$task_dir/bin"
printf '# 中文笔记\n\n测试正文\n' > "$task_dir/library/中文 笔记.md"
printf 'legacy note\n' > "$task_dir/legacy/legacy.md"
cat > "$task_dir/bin/defaults" <<'EOF'
#!/bin/bash
if [[ "$1" == "read" && "$2" == "com.mdown.app" && "$3" == "storageUrl" && -n "${MDOWN_SMOKE_PREF_DIR:-}" ]]; then
    printf '%s
' "$MDOWN_SMOKE_PREF_DIR"
    exit 0
fi
if [[ "$1" == "read" && "$2" == "com.tw93.miaoyan" && "$3" == "storageUrl" && -n "${MDOWN_SMOKE_LEGACY_PREF_DIR:-}" ]]; then
    printf '%s
' "$MDOWN_SMOKE_LEGACY_PREF_DIR"
    exit 0
fi
exit 1
EOF
printf '#!/bin/bash\nprintf "%%s\n" "$@" > "$MDOWN_SMOKE_OPEN_LOG"\n' > "$task_dir/bin/open"
chmod +x "$task_dir/bin/defaults" "$task_dir/bin/open"
export PATH="$task_dir/bin:$PATH"
export MDOWN_SMOKE_OPEN_LOG="$task_dir/open.log"
export MDOWN_PATH="$task_dir/library"
export MIAOYAN_PATH="$task_dir/legacy"
[[ "$(bash "$cli" cat '中文 笔记')" == $'# 中文笔记\n\n测试正文' ]]
[[ "$(bash "$cli" list .)" == './中文 笔记.md' ]]
[[ "$(bash "$cli" search '测试正文')" == '中文 笔记.md:3:测试正文' ]]
[[ "$(env -u MDOWN_PATH bash "$cli" cat legacy)" == 'legacy note' ]]
[[ "$(env -u MDOWN_PATH -u MIAOYAN_PATH MDOWN_SMOKE_PREF_DIR="$task_dir/library" MDOWN_SMOKE_LEGACY_PREF_DIR="$task_dir/legacy" bash "$cli" cat '中文 笔记')" == $'# 中文笔记\n\n测试正文' ]]
[[ "$(env -u MDOWN_PATH -u MIAOYAN_PATH MDOWN_SMOKE_LEGACY_PREF_DIR="$task_dir/legacy" bash "$cli" cat legacy)" == 'legacy note' ]]
bash "$cli" open '中文 笔记'
[[ "$(<"$MDOWN_SMOKE_OPEN_LOG")" == $'-a\nMdown\n'"$task_dir/library/中文 笔记.md" ]]
bash "$cli" new "单引号'与空格" '正文 & 内容'
[[ "$(<"$MDOWN_SMOKE_OPEN_LOG")" == 'mdown://new/?title=%E5%8D%95%E5%BC%95%E5%8F%B7%27%E4%B8%8E%E7%A9%BA%E6%A0%BC&txt=%E6%AD%A3%E6%96%87%20%26%20%E5%86%85%E5%AE%B9' ]]
[[ "$(bash "$cli" help)" == *'mdown <command>'* ]]
printf 'PASS: CLI 主命令、中文路径、新旧变量优先级和新链接\n'
