#!/bin/bash
set -euo pipefail

locale=$(defaults read -g AppleLanguages 2>/dev/null | awk 'match($0, /[a-z][a-z]([-_][A-Za-z0-9]+)*/) {print substr($0,RSTART,RLENGTH); exit}' || true)
locale=${locale:-$(defaults read -g AppleLocale 2>/dev/null || true)}
case "${locale//_/-}" in
  zh-Hans*) language=0 ;;
  zh-Hant*|zh-TW*|zh-HK*|zh-MO*) language=1 ;;
  zh*) language=0 ;;
  *) language=2 ;;
esac
text() { local messages=("$@"); printf '%s' "${messages[$language]}"; }
progress() { step=$(text "$@"); printf '→ %s\n' "$step"; }
fail() { text "$@" >&2; printf '\n' >&2; exit 1; }
export LC_ALL=C
cask=qixiaoyu27/tap/mac-explorer
project=https://github.com/qixiaoyu27/Mac-Explorer
work=''; result=''; app=''
step=$(text '检查系统' '檢查系統' 'Checking the system')
finish() {
  status=$?
  trap - EXIT
  if [[ "$status" == 0 ]]; then
    printf '\n✓ %s\n  %s\n' "$result" "$app"
  else
    printf '\n✗ %s\n' "$(text "未完成：$step" "未完成：$step" "Could not complete: $step")" >&2
  fi
  printf '\n%s\n%s\n' "$(text '喜欢 Mac Explorer？欢迎点亮 🌟 Star，支持项目继续完善。' '喜歡 Mac Explorer？歡迎點亮 🌟 Star，支持專案持續完善。' 'Enjoy Mac Explorer? Give it a 🌟 Star to support the project.')" "$project"
  [[ -z "$work" ]] || rm -rf "$work"
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
[[ "$(uname -s)" == Darwin && "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" == 1 ]] || fail '需要 Apple Silicon Mac。' '需要 Apple Silicon Mac。' 'An Apple Silicon Mac is required.'
[[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 13 && "$EUID" -ne 0 ]] || fail '需要 macOS 13 或更高版本，请勿使用 sudo。' '需要 macOS 13 或更新版本，請勿使用 sudo。' 'macOS 13 or later is required. Run without sudo.'
work=$(mktemp -d "${TMPDIR:-/tmp}/mac-explorer-brew.XXXXXX")

brew=$(command -v brew || true)
if [[ -z "$brew" && -x /opt/homebrew/bin/brew ]]; then brew=/opt/homebrew/bin/brew; fi
if [[ -z "$brew" ]]; then
  progress '安装 Homebrew（可能需要输入 Mac 登录密码）' '安裝 Homebrew（可能需要輸入 Mac 登入密碼）' 'Installing Homebrew (your Mac login password may be required)'
  curl --fail --location --silent --show-error --retry 2 --connect-timeout 15 --max-time 120 --proto '=https' --proto-redir '=https' \
    https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$work/homebrew.sh"
  /bin/bash "$work/homebrew.sh"
  brew=/opt/homebrew/bin/brew
fi
[[ -x "$brew" ]] || fail '未找到可用的 Homebrew。' '找不到可用的 Homebrew。' 'A working Homebrew installation was not found.'
export PATH="${brew%/*}:$PATH"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
run_brew() {
  "$brew" "$@" > "$work/brew.log" || { cat "$work/brew.log" >&2; return 1; }
}
progress '检查 Mac Explorer 更新' '檢查 Mac Explorer 更新' 'Checking for Mac Explorer updates'
run_brew update --quiet
run_brew tap qixiaoyu27/tap
# Older Homebrew versions lack the built-in trust command.
if [[ $("$brew" command trust 2>/dev/null) == */Library/Homebrew/cmd/trust.rb ]]; then
  run_brew trust --cask "$cask"
fi
"$brew" info --json=v2 --cask "$cask" > "$work/info.json"
latest=$(/usr/bin/plutil -extract casks.0.version raw -o - "$work/info.json")
checksum=$(/usr/bin/plutil -extract casks.0.sha256 raw -o - "$work/info.json")
registered=$(/usr/bin/plutil -extract casks.0.installed raw -o - "$work/info.json" 2>/dev/null) || registered=''
[[ "$registered" != null ]] || registered=''
app=$(/usr/bin/plutil -extract casks.0.artifacts.0.target raw -o - "$work/info.json" 2>/dev/null) || app='/Applications/Mac Explorer.app'
[[ "$latest" =~ ^[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$ && "$checksum" =~ ^[a-fA-F0-9]{64}$ && "$app" == /*/'Mac Explorer.app' ]] || fail '安装信息无效。' '安裝資訊無效。' 'Invalid installation metadata.'
if [[ -z "$registered" && ! -e "$app" && ! -L "$app" && ( -e "$HOME/Applications/Mac Explorer.app" || -L "$HOME/Applications/Mac Explorer.app" ) ]]; then
  app="$HOME/Applications/Mac Explorer.app"
fi
validate_app() {
  local executable
  [[ -d "$app" && ! -L "$app" && ! -L "$app/Contents" && ! -L "$app/Contents/Info.plist" && ! -L "$app/Contents/MacOS" ]] || fail '应用路径无效，未替换应用。' '應用程式路徑無效，未替換應用程式。' 'Invalid app path; the app was not replaced.'
  identity=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
  executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")
  case "$identity:$executable" in
    'local.macexplorer.native-prototype:MacExplorerNative'|'local.macexplorer.desktop:Mac Explorer') ;;
    *) fail '目标位置不是 Mac Explorer，未替换应用。' '目標位置不是 Mac Explorer，未替換應用程式。' 'The destination is not Mac Explorer; the app was not replaced.' ;;
  esac
  [[ -x "$app/Contents/MacOS/$executable" && ! -L "$app/Contents/MacOS/$executable" ]] || fail '应用执行文件无效。' '應用程式執行檔無效。' 'Invalid app executable.'
  /usr/bin/codesign --verify --deep --strict "$app"
  current=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
  [[ "$current" =~ ^[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$ ]] || fail '应用版本无效。' '應用程式版本無效。' 'Invalid app version.'
}
current=''; identity=''; comparison=-1
if [[ -e "$app" || -L "$app" ]]; then
  validate_app
  comparison=$(awk -v a="$current" -v b="$latest" 'BEGIN{split(a,x,".");split(b,y,".");for(i=1;i<=3;i++){if(x[i]+0>y[i]+0){print 1;exit}if(x[i]+0<y[i]+0){print -1;exit}}print 0}')
fi
before="$current"; before_identity="$identity"
adopt() {
  progress '将现有 Mac Explorer 纳入 Homebrew 管理' '將現有 Mac Explorer 納入 Homebrew 管理' 'Adding the existing Mac Explorer to Homebrew'
  run_brew install --cask --no-ask --adopt --appdir "${app%/*}" "$cask"
  registered="$latest"
}
if [[ "$comparison" == 1 || ( "$comparison" == 0 && "$identity" == local.macexplorer.native-prototype ) ]]; then
  if [[ -z "$registered" ]]; then adopt; fi
  if [[ "$comparison" == 1 ]]; then
    result=$(text "已保留较新版本 Mac Explorer $current" "已保留較新版本 Mac Explorer $current" "Kept the newer Mac Explorer $current")
  else
    result=$(text "Mac Explorer $current 已是最新版" "Mac Explorer $current 已是最新版" "Mac Explorer $current is up to date")
  fi
  exit 0
fi
pinned=$(/usr/bin/plutil -extract casks.0.pinned raw -o - "$work/info.json" 2>/dev/null) || pinned=false
[[ "$pinned" != true ]] || fail 'Mac Explorer 已固定版本，请先在 Homebrew 中解除固定。' 'Mac Explorer 已固定版本，請先在 Homebrew 中解除固定。' 'Mac Explorer is pinned. Unpin it in Homebrew before updating.'
progress "下载 Mac Explorer $latest" "下載 Mac Explorer $latest" "Downloading Mac Explorer $latest"
run_brew fetch --cask "$cask"
app_running() { /bin/ps -axo command= | awk -v prefix="$app/Contents/MacOS/" 'index($0,prefix)==1 {found=1} END{exit !found}'; }
if [[ -n "$current" ]] && app_running; then
  progress '退出 Mac Explorer 以完成更新' '結束 Mac Explorer 以完成更新' 'Quitting Mac Explorer to finish the update'
  /usr/bin/osascript -e "tell application id \"$identity\" to quit"
  for ((attempt=0; attempt<30; attempt++)); do if ! app_running; then break; fi; sleep 1; done
  if app_running; then fail '应用尚未退出，请退出后重新运行此命令。' '應用程式尚未結束，請結束後重新執行此指令。' 'The app is still running. Quit it and run this command again.'; fi
fi
if [[ -n "$before" ]]; then
  validate_app
  [[ "$current" == "$before" && "$identity" == "$before_identity" ]] || fail '应用已发生变化，请重新运行此命令。' '應用程式已變更，請重新執行此指令。' 'The app changed. Run this command again.'
fi
if [[ -z "$registered" && -n "$current" ]]; then adopt; fi
progress "安装 Mac Explorer $latest" "安裝 Mac Explorer $latest" "Installing Mac Explorer $latest"
if [[ -z "$registered" ]]; then
  run_brew install --cask --no-ask --require-sha --appdir "${app%/*}" "$cask"
elif [[ "$registered" == "$latest" || -z "$current" || "$identity" == local.macexplorer.desktop ]]; then
  # Adoption records the cask version without updating the existing app files.
  run_brew reinstall --cask --no-ask --require-sha "$cask"
else
  run_brew upgrade --cask --greedy --no-ask "$cask"
fi
validate_app
[[ "$current" == "$latest" && "$identity" == local.macexplorer.native-prototype ]] || fail '安装后的版本与目标版本不符。' '安裝後的版本與目標版本不符。' 'The installed version does not match the requested version.'
if [[ -z "$before" ]]; then
  result=$(text "已安装 Mac Explorer $current" "已安裝 Mac Explorer $current" "Installed Mac Explorer $current")
else
  result=$(text "已更新 Mac Explorer：$before → $current" "已更新 Mac Explorer：$before → $current" "Updated Mac Explorer: $before → $current")
fi
