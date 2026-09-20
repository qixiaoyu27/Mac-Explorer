#!/bin/bash
# Install the latest official Apple Silicon release using macOS built-in tools.
set -euo pipefail

fail() { printf '安装失败：%s\n' "$*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || fail '目前仅支持 macOS。'
[[ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" == 1 ]] || fail '目前仅支持 Apple Silicon（M 系列芯片）。'
[[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 13 ]] || fail '需要 macOS 13 或更高版本。'
[[ "$EUID" -ne 0 ]] || fail '请使用普通用户运行，不要加 sudo。'
allow_unnotarized="${MAC_EXPLORER_ALLOW_UNNOTARIZED:-0}"
[[ "$allow_unnotarized" == 0 || "$allow_unnotarized" == 1 ]] || fail 'MAC_EXPLORER_ALLOW_UNNOTARIZED 只能是 0 或 1。'

repo='https://github.com/qixiaoyu27/Mac-Explorer'
install_dir="${MAC_EXPLORER_INSTALL_DIR:-$HOME/Applications}"
# Update an existing system-wide installation in place instead of creating a duplicate.
if [[ -z "${MAC_EXPLORER_INSTALL_DIR:-}" && ! -e "$install_dir/Mac Explorer.app" && -e '/Applications/Mac Explorer.app' ]]; then
  install_dir='/Applications'
fi
[[ "$install_dir" == /* ]] || fail '安装目录必须是绝对路径。'
mkdir -p "$install_dir"
[[ -w "$install_dir" ]] || fail "无法写入 $install_dir，请选择可写目录后重试。"
destination="$install_dir/Mac Explorer.app"
[[ ! -L "$destination" ]] || fail '目标应用是符号链接，请先自行检查。'
if [[ -e "$destination" ]]; then
  identity=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$destination/Contents/Info.plist" 2>/dev/null || true)
  [[ "$identity" == local.macexplorer.desktop ]] || fail '目标位置存在其他应用，未作修改。'
fi
app_running() { pgrep -f '/Mac Explorer[.]app/Contents/MacOS/Mac Explorer($| )' >/dev/null; }
app_running && fail '请先退出 Mac Explorer，再重新运行此命令。'

work=$(mktemp -d "${TMPDIR:-/tmp}/mac-explorer-download.XXXXXX")
stage=''
backup=''
installed=0
cleanup() {
  status=$?
  if [[ "$installed" == 0 && -n "$backup" && ! -e "$destination" && -d "$backup" ]]; then
    mv "$backup" "$destination" || printf '旧版本保留在：%s\n' "$backup" >&2
  fi
  [[ -z "$stage" ]] || rm -rf "$stage"
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fetch() { curl --fail --location --silent --show-error --retry 2 --connect-timeout 15 --max-time 600 --proto '=https' --tlsv1.2 "$1" -o "$2"; }

printf '正在查询最新版…\n'
fetch "$repo/releases/latest/download/SHA256SUMS.txt" "$work/checksums"
entry=$(awk 'length($1)==64 && $1 !~ /[^[:xdigit:]]/ && $2 ~ /^Mac-Explorer-[0-9]+\.[0-9]+\.[0-9]+-mac-arm64\.zip$/ { print $1 " " $2 }' "$work/checksums")
[[ -n "$entry" && "$entry" != *$'\n'* ]] || fail '发布校验文件格式不正确。'
expected=${entry%% *}
archive=${entry#* }
version=${archive#Mac-Explorer-}
version=${version%-mac-arm64.zip}
printf '正在下载 Mac Explorer %s…\n' "$version"
# Pin the ZIP to the version selected from the checksum file, even during a new release.
fetch "$repo/releases/download/v$version/$archive" "$work/$archive"
actual=$(shasum -a 256 "$work/$archive" | awk '{print $1}')
[[ "$actual" == "$expected" ]] || fail '下载校验不一致，原安装未作修改。'
printf '校验通过，正在准备安装…\n'
ditto -x -k "$work/$archive" "$work/unpacked"
source_app="$work/unpacked/Mac Explorer.app"
[[ -d "$source_app" && ! -L "$source_app" ]] || fail '安装包中缺少应用。'
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$source_app/Contents/Info.plist")" == local.macexplorer.desktop ]] || fail '应用标识不匹配。'
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$source_app/Contents/Info.plist")" == "$version" ]] || fail '应用版本不匹配。'
codesign --verify --deep --strict "$source_app"
stage=$(mktemp -d "$install_dir/.mac-explorer-install.XXXXXX")
ditto "$source_app" "$stage/Mac Explorer.app"
codesign --verify --deep --strict "$stage/Mac Explorer.app"
if [[ "$allow_unnotarized" == 1 ]]; then
  printf '按你的选择，仅移除已校验 Mac Explorer 的下载隔离标记；不更改系统安全设置。\n'
  # -s acts on symlinks themselves, never on targets outside the staged bundle.
  /usr/bin/xattr -drs com.apple.quarantine "$stage/Mac Explorer.app" || fail '无法移除应用隔离标记，原安装未作修改。'
  codesign --verify --deep --strict "$stage/Mac Explorer.app"
fi
app_running && fail '下载期间应用被打开，请先退出后重试。'
if [[ -e "$destination" ]]; then
  backup_dir="$install_dir/.Mac Explorer Backups"
  mkdir -p "$backup_dir"
  backup_parent=$(mktemp -d "$backup_dir/$(date +%Y%m%d-%H%M%S).XXXXXX")
  backup="$backup_parent/Mac Explorer.app"
  mv "$destination" "$backup"
fi
mv "$stage/Mac Explorer.app" "$destination"
installed=1
launch_message='可从应用程序目录打开'
if [[ "${MAC_EXPLORER_NO_OPEN:-0}" != 1 ]]; then
  if open "$destination"; then launch_message='已请求启动应用'; else launch_message='请从应用程序目录手动打开'; fi
fi

show_completion() {
  local title='' success='' muted='' accent='' reset=''
  if [[ -t 1 && "${TERM:-dumb}" != dumb && -z "${NO_COLOR+x}" ]]; then
    title=$'\033[1;36m'; success=$'\033[1;32m'; muted=$'\033[2m'; accent=$'\033[1;33m'; reset=$'\033[0m'
  fi
  # An open right edge keeps full paths/URLs copyable without padding or clipping.
  printf '\n  %s╭─ MAC EXPLORER ─────────────────%s\n' "$title" "$reset"
  printf '  %s│%s\n' "$muted" "$reset"
  printf '  %s│%s  %s✓ 安装完成%s  v%s\n' "$muted" "$reset" "$success" "$reset" "$version"
  printf '  %s│%s  %s\n' "$muted" "$reset" "$launch_message"
  printf '  %s│%s\n' "$muted" "$reset"
  printf '  %s│  安装位置%s\n' "$muted" "$reset"
  printf '  %s│%s  %s\n' "$muted" "$reset" "$destination"
  if [[ -n "$backup" ]]; then
    printf '  %s│%s\n' "$muted" "$reset"
    printf '  %s│  旧版本备份%s\n' "$muted" "$reset"
    printf '  %s│%s  %s\n' "$muted" "$reset" "$backup"
  fi
  printf '  %s│%s\n' "$muted" "$reset"
  printf '  %s├───────────────────────────────%s\n' "$muted" "$reset"
  printf '  %s│%s\n' "$muted" "$reset"
  printf '  %s│%s  %s⭐ Star · 支持 Mac Explorer%s\n' "$muted" "$reset" "$accent" "$reset"
  printf '  %s│%s  用 Mac 更顺手了？点亮一颗星，支持持续更新。\n' "$muted" "$reset"
  printf '  %s│%s  %s\n' "$muted" "$reset" "$repo"
  printf '  %s│%s\n' "$muted" "$reset"
  printf '  %s╰───────────────────────────────%s\n\n' "$title" "$reset"
  printf '  %s临时签名 · 未经 Apple 公证；若系统拦截，请查看安装说明。%s\n' "$muted" "$reset"
  printf '  %s#下载与安装\n\n' "$repo"
}
show_completion
