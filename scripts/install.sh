#!/bin/bash
# Install the latest official Apple Silicon release using macOS built-in tools.
set -euo pipefail

fail() { printf '安装失败：%s\n' "$*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || fail '目前仅支持 macOS。'
[[ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" == 1 ]] || fail '目前仅支持 Apple Silicon（M 系列芯片）。'
[[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 13 ]] || fail '需要 macOS 13 或更高版本。'
[[ "$EUID" -ne 0 ]] || fail '请使用普通用户运行，不要加 sudo。'

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
printf '\n已安装 Mac Explorer %s：%s\n' "$version" "$destination"
[[ -z "$backup" ]] || printf '旧版本备份：%s\n' "$backup"
printf '安装完成。此版本为临时签名、未经 Apple 公证；若系统拦截，请按 README 的首次打开说明处理。\n'
printf '安装说明：https://github.com/qixiaoyu27/Mac-Explorer#下载与安装\n'
if [[ "${MAC_EXPLORER_NO_OPEN:-0}" != 1 ]]; then
  open "$destination" || printf '应用已安装，请从应用程序目录手动打开。\n'
fi
