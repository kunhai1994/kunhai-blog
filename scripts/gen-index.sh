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

show_help() {
    cat <<'HELP'
gen-index.sh — 递归扫描目录，为每个子目录生成 Docsify 兼容的 README.md 索引

用法:
  ./scripts/gen-index.sh <目录名> [标题]    递归扫描指定目录及所有子目录
  ./scripts/gen-index.sh --all              递归扫描博客根目录下所有子目录
  ./scripts/gen-index.sh --help             显示本帮助信息

参数:
  <目录名>    相对于博客根目录的路径，如 xhs-research、claude-code
  [标题]      可选，自定义根目录 README.md 的标题，默认使用目录名

示例:
  ./scripts/gen-index.sh xhs-research                    # 使用目录名作为标题
  ./scripts/gen-index.sh xhs-research "小红书调研工具"      # 自定义标题
  ./scripts/gen-index.sh claude-code/systemPrompt         # 只处理某个子目录
  ./scripts/gen-index.sh --all                            # 处理所有目录

生成规则:
  - 子目录 → 列在「目录」分类下，生成可点击链接
  - .md 文件（排除 README/_sidebar/_coverpage）→ 列在「文章」分类下
  - 自动跳过: .开头的目录、scripts、.git、node_modules

注意:
  - 会覆盖目标目录下的 README.md，请勿手动编辑被管理的 README.md
HELP
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    show_help
    exit 0
fi

if [ -z "${1:-}" ]; then
    show_help
    exit 1
fi

recurse "$1" "${2:-}"
