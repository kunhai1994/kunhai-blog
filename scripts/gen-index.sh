#!/bin/bash
#
# 递归扫描目录，生成 Docsify 兼容的目录索引，写入每个目录的 README.md
#
# 用法:
#   ./scripts/gen-index.sh xhs-research          # 递归扫描 xhs-research/ 及所有子目录
#   ./scripts/gen-index.sh xhs-research "小红书调研工具"  # 自定义根目录标题
#   ./scripts/gen-index.sh --all                  # 递归扫描所有目录

set -euo pipefail

BLOG_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# 跳过的目录名
SKIP_DIRS=("scripts" ".git" "node_modules")

should_skip() {
    local name="$1"
    [[ "$name" == .* ]] && return 0
    for skip in "${SKIP_DIRS[@]}"; do
        [ "$name" = "$skip" ] && return 0
    done
    return 1
}

generate_index() {
    local dir="$1"
    local title="${2:-$(basename "$dir")}"
    local dir_path="${BLOG_ROOT}/${dir}"

    if [ ! -d "$dir_path" ]; then
        echo "目录不存在: $dir_path"
        return 1
    fi

    local has_subdirs=false
    local has_files=false
    local output=""
    output+="# ${title}\n\n"

    # 列出子目录
    for sub in "$dir_path"/*/; do
        [ ! -d "$sub" ] && continue
        local name
        name=$(basename "$sub")
        should_skip "$name" && continue

        if [ "$has_subdirs" = false ]; then
            output+="## 目录\n\n"
            has_subdirs=true
        fi
        output+="- [${name}](${dir}/${name}/)\n"
    done

    # 列出当前目录下的 .md 文件（非 README、非 _sidebar）
    for md in "$dir_path"/*.md; do
        [ ! -f "$md" ] && continue
        local md_name
        md_name=$(basename "$md" .md)
        [ "$md_name" = "README" ] && continue
        [ "$md_name" = "_sidebar" ] && continue
        [ "$md_name" = "_coverpage" ] && continue
        if [ "$has_files" = false ]; then
            [ "$has_subdirs" = true ] && output+="\n"
            output+="## 文章\n\n"
            has_files=true
        fi
        output+="- [${md_name}](${dir}/${md_name}.md)\n"
    done

    # 写入 README.md
    echo -e "$output" > "$dir_path/README.md"
    echo "已更新: ${dir_path}/README.md"
}

# 递归处理目录及其所有子目录
recurse() {
    local dir="$1"
    local title="${2:-$(basename "$dir")}"
    local dir_path="${BLOG_ROOT}/${dir}"

    generate_index "$dir" "$title"

    # 递归处理子目录
    for sub in "$dir_path"/*/; do
        [ ! -d "$sub" ] && continue
        local name
        name=$(basename "$sub")
        should_skip "$name" && continue
        recurse "${dir}/${name}"
    done
}

# --all 模式
if [ "${1:-}" = "--all" ]; then
    for d in "$BLOG_ROOT"/*/; do
        [ ! -d "$d" ] && continue
        name=$(basename "$d")
        should_skip "$name" && continue
        recurse "$name"
    done
    exit 0
fi

if [ -z "${1:-}" ]; then
    echo "用法: $0 <目录名> [标题]"
    echo "       $0 --all"
    exit 1
fi

recurse "$1" "${2:-}"
