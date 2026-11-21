#!/bin/bash
# Install the native application, including upgrades from the official Electron application.
set -euo pipefail
export LC_ALL=C
fail() { printf '安装失败：%s\n' "$*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin && "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" == 1 ]] || fail '需要 Apple Silicon Mac。'
[[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 13 && "$EUID" -ne 0 ]] || fail '需要 macOS 13 或更高版本，请勿使用 sudo。'
install_and_open=0
allow_unnotarized="${MAC_EXPLORER_ALLOW_UNNOTARIZED:-0}"
case "$#:${1:-}" in
  0:) ;;
  1:--install-and-open)
    [[ -t 0 ]] || fail '请在终端运行此命令并确认安装。'
    printf '%s\n' 'Mac Explorer 未经 Apple 公证。继续会移除本次安装的应用的下载隔离标记，并打开应用。' >&2
    printf '%s\n' 'Mac Explorer is not Apple-notarized. Continuing removes download quarantine from this copy and opens the app.' >&2
    printf '继续 / Continue? [y/N] ' >&2
    if ! IFS= read -r answer || [[ "$answer" != [yY] ]]; then
      printf '已取消安装 / Installation canceled.\n'
      exit 0
    fi
    install_and_open=1
    allow_unnotarized=1
    ;;
  *) fail '无效的安装选项。' ;;
esac
[[ "$allow_unnotarized" == 0 || "$allow_unnotarized" == 1 ]] || fail 'MAC_EXPLORER_ALLOW_UNNOTARIZED 只能是 0 或 1。'
repo='https://github.com/qixiaoyu27/Mac-Explorer'
install_dir="${MAC_EXPLORER_NATIVE_INSTALL_DIR:-${MAC_EXPLORER_INSTALL_DIR:-/Applications}}"
prepared="${MAC_EXPLORER_NATIVE_PREPARED:-${MAC_EXPLORER_PREPARED_UPDATE:-}}"
[[ "$install_dir" == /* ]] || fail '安装目录必须是绝对路径。'
mkdir -p "$install_dir"
install_dir=$(cd "$install_dir" && pwd -P)
destination="$install_dir/Mac Explorer.app"
[[ -w "$install_dir" && ! -L "$destination" ]] || fail '安装位置不可写或目标是符号链接。'
existing="$destination"
legacy_app="$HOME/Applications/Mac Explorer.app"
if [[ "$install_dir" == /Applications && ! -e "$destination" && ( -e "$legacy_app" || -L "$legacy_app" ) ]]; then existing="$legacy_app"; fi
[[ ! -L "$existing" ]] || fail '已有应用是符号链接，请先自行检查。'
work=$(mktemp -d "${TMPDIR:-/tmp}/mac-explorer-native.XXXXXX")
stage=''; backup=''; installed=0
cleanup() {
  status=$?
  if [[ "$installed" == 0 && -n "$backup" && -d "$backup" && ! -e "$existing" && ! -L "$existing" ]]; then mv "$backup" "$existing" || printf '旧版本保留在：%s\n' "$backup" >&2; fi
  if [[ "$installed" == 0 && -n "$backup" && -d "$backup" ]]; then printf '旧版本保留在：%s\n' "$backup" >&2; fi
  if [[ -n "$stage" && ( "$installed" == 1 || -z "$backup" || ! -e "$backup" ) ]]; then rm -rf "$stage"; fi
  rm -rf "$work"; exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fetch() { curl --fail --location --silent --show-error --retry 2 --connect-timeout 15 --max-time 900 --max-filesize 2147483648 --proto '=https' --proto-redir '=https' --tlsv1.2 "$1" -o "$2"; }
if [[ -n "$prepared" ]]; then
  [[ "$prepared" == /* && -d "$prepared" && ! -L "$prepared" ]] || fail '无效的原生更新目录。'
  cp "$prepared/SHA256SUMS-native.txt" "$work/checksums"
else
  fetch "$repo/releases/latest/download/SHA256SUMS-native.txt" "$work/checksums"
fi
entry=$(awk 'length($1)==64 && $1 !~ /[^[:xdigit:]]/ && $2 ~ /^Mac-Explorer-Native-[0-9]+\.[0-9]+\.[0-9]+-mac-arm64\.zip$/ {print $1 " " $2}' "$work/checksums")
[[ -n "$entry" && "$entry" != *$'\n'* ]] || fail '未找到唯一的原生更新包。'
expected=${entry%% *}; archive=${entry#* }; version=${archive#Mac-Explorer-Native-}; version=${version%-mac-arm64.zip}
[[ "$version" =~ ^[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$ ]] || fail '无效的版本号。'
validate_app() {
  local app="$1" target_version="${2:-}" identity executable actual expected_executable=MacExplorerNative
  [[ -d "$app" && ! -L "$app" && ! -L "$app/Contents" && ! -L "$app/Contents/Info.plist" && ! -L "$app/Contents/MacOS" && ! -L "$app/Contents/MacOS/MacExplorerNative" ]] || fail '原生应用路径无效。'
  identity=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")
  executable=$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$app/Contents/Info.plist")
  actual=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
  if [[ -z "$target_version" && "$identity" == local.macexplorer.desktop ]]; then expected_executable='Mac Explorer';
  else [[ "$identity" == local.macexplorer.native-prototype ]] || fail '应用标识不匹配；未替换任何应用。'; fi
  [[ "$executable" == "$expected_executable" && ! -L "$app/Contents/MacOS/$executable" && "$actual" =~ ^[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$ && -x "$app/Contents/MacOS/$executable" ]] || fail '应用标识或执行文件不匹配；未替换任何应用。'
  [[ -z "$target_version" || "$actual" == "$target_version" ]] || fail '应用版本不匹配。'
  /usr/bin/lipo "$app/Contents/MacOS/$executable" -verify_arch arm64 || fail '原生应用架构无效。'
  /usr/bin/codesign --verify --deep --strict "$app" || fail '应用签名无效。'
}
if [[ -e "$existing" ]]; then
  validate_app "$existing"
  current=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$existing/Contents/Info.plist")
  current_identity=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$existing/Contents/Info.plist")
  comparison=$(awk -v a="$current" -v b="$version" 'BEGIN{split(a,x,".");split(b,y,".");for(i=1;i<=3;i++){if(x[i]+0>y[i]+0){print 1;exit}if(x[i]+0<y[i]+0){print -1;exit}}print 0}')
  if [[ "$comparison" == 1 || ( "$comparison" == 0 && "$current_identity" == local.macexplorer.native-prototype && "$install_and_open" == 0 ) ]]; then
    printf '保留当前版本 v%s。\n' "$current"
    exit 0
  fi
fi
app_running() {
  /bin/ps -axo command= | /usr/bin/awk -v prefix="$existing/Contents/MacOS/" 'index($0,prefix)==1 {found=1} END{exit !found}'
}
app_running && fail '请先退出 Mac Explorer 后重试。'
if [[ -n "$prepared" ]]; then cp "$prepared/$archive" "$work/$archive"; else fetch "$repo/releases/download/v$version/$archive" "$work/$archive"; fi
[[ "$(/usr/bin/stat -f%z "$work/$archive")" -le 2147483648 ]] || fail '更新包大小无效。'
actual=$(/usr/bin/shasum -a 256 "$work/$archive" | awk '{print $1}')
[[ "$actual" == "$expected" ]] || fail '更新包校验失败；原安装未作修改。'
/usr/bin/unzip -Z -1 "$work/$archive" > "$work/entries"
[[ -s "$work/entries" ]] || fail '更新压缩包为空。'
count=0
while IFS= read -r name; do
  count=$((count+1)); [[ "$count" -le 100000 ]] || fail '更新包项目过多。'
  [[ "$name" == 'Mac Explorer.app/'* && "$name" != *'\'* && "$name" != *$'\r'* && "/$name/" != *'/../'* && "/$name/" != *'/./'* ]] || fail '更新包路径无效。'
done < "$work/entries"
uncompressed=$(/usr/bin/unzip -Z -t "$work/$archive" | /usr/bin/awk '$4=="bytes" && $5=="uncompressed," {print $3}')
[[ "$uncompressed" =~ ^[0-9]+$ && "$uncompressed" -le 2147483648 ]] || fail '更新压缩包展开大小无效。'
/usr/bin/unzip -Z -l "$work/$archive" > "$work/attributes"
if /usr/bin/awk '/^l/{found=1} END{exit !found}' "$work/attributes"; then fail '更新包包含符号链接。'; fi
/usr/bin/ditto -x -k "$work/$archive" "$work/unpacked"
source_app="$work/unpacked/Mac Explorer.app"
validate_app "$source_app" "$version"
stage=$(mktemp -d "$install_dir/.mac-explorer-native.XXXXXX")
/usr/bin/ditto "$source_app" "$stage/Mac Explorer.app"
validate_app "$stage/Mac Explorer.app" "$version"
if [[ "$allow_unnotarized" == 1 ]]; then /usr/bin/xattr -dr com.apple.quarantine "$stage/Mac Explorer.app" || fail '无法移除下载隔离标记；原安装未作修改。'; fi
validate_app "$stage/Mac Explorer.app" "$version"
app_running && fail '应用已被打开，请先退出后重试。'
if [[ -e "$existing" ]]; then validate_app "$existing"; backup="$stage/previous.app"; mv "$existing" "$backup"; fi
[[ ! -e "$destination" && ! -L "$destination" ]] || fail '目标位置已出现其他应用，已停止安装。'
mv "$stage/Mac Explorer.app" "$destination"
installed=1
printf '已安装原生版本 v%s：%s\n' "$version" "$destination"
if [[ "${MAC_EXPLORER_NATIVE_NO_OPEN:-${MAC_EXPLORER_NO_OPEN:-0}}" != 1 ]]; then /usr/bin/open "$destination" || printf '请手动打开应用。\n'; fi
