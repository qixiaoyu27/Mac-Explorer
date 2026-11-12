import AppKit
import ExplorerCore

final class NativeSystemSettingsView: SurfaceView {
  var preferredHeight: CGFloat { status.stringValue.isEmpty ? 28 : 58 }
  var onHeightChange: (() -> Void)?
  private let integration: NativeSystemIntegration
  private let viewer = EDButton(title: NL("接收系统文件定位请求"), style: .checkbox)
  private let help = NativeHelpButton(text: NL("处理部分系统“在文件夹中显示”请求，不接管桌面双击；关闭后恢复原设置。"), accessibilityLabel: NL("系统文件查看器说明"))
  private let status = label("", size: 12)
  init(integration: NativeSystemIntegration) {
    self.integration = integration; super.init(frame: .zero); color = .clear
    [viewer, help, status].forEach(addSubview)
    viewer.onPress = { [weak self] in self?.toggleViewer() }
    refreshViewer()
  }
  required init?(coder: NSCoder) { fatalError() }
  private func refreshViewer() {
    do { let value = try integration.fileViewer.perform("status"); viewer.checked = value.enabled; viewer.isEnabled = !value.enabled || value.canRestore; if !value.error.isEmpty { status.stringValue = NL(value.error) } else if value.staleViewer { status.stringValue = NL("当前文件查看器已不可用") } }
    catch { viewer.isEnabled = false; status.stringValue = NL(error.localizedDescription) }
  }
  @objc private func toggleViewer() {
    let enabling = !viewer.checked
    let alert = NSAlert(); alert.messageText = enabling ? NL("使用 Mac Explorer 显示文件？") : NL("恢复原文件查看器设置？")
    alert.addButton(withTitle: NL("确定")); alert.addButton(withTitle: NL("取消"))
    guard alert.runModal() == .alertFirstButtonReturn else { refreshViewer(); return }
    integration.suppressFileViewerPrompt()
    do { _ = try integration.fileViewer.perform(enabling ? "enable" : "restore"); status.stringValue = NL("已保存") }
    catch { status.stringValue = NL(error.localizedDescription) }
    refreshViewer(); onHeightChange?()
  }
  override func layout() {
    super.layout(); let width = bounds.width
    viewer.frame = NSRect(x: 0, y: 0, width: width - 32, height: 28); help.frame = NSRect(x: width - 24, y: 0, width: 24, height: 28)
    status.frame = NSRect(x: 0, y: 30, width: width, height: 28); status.maximumNumberOfLines = 2
  }
}

final class NativeDesktopSettingsView: SurfaceView {
  var preferredHeight: CGFloat { status.stringValue.isEmpty ? 72 : 100 }
  var onHeightChange: (() -> Void)?
  private let desktop: NativeDesktop
  let toggle = EDButton(title: NL("使用 Mac Explorer 管理桌面"), style: .checkbox)
  let restore = EDButton(title: NL("恢复 Finder 桌面"), style: .secondary)
  private let help = NativeHelpButton(text: NL("桌面图标自动排列在主显示器，双击文件夹打开 Mac Explorer。其他显示器显示壁纸；动态壁纸使用静态图像。关闭或退出应用后恢复 Finder 桌面。"), accessibilityLabel: NL("桌面模式说明"))
  private let status = label("", size: 12)
  private var observer: NSObjectProtocol?

  init(desktop: NativeDesktop) {
    self.desktop = desktop; super.init(frame: .zero); color = .clear
    [toggle, restore, help, status].forEach(addSubview)
    toggle.onPress = { [weak self] in self?.setEnabled(!desktop.isEnabled) }
    restore.onPress = { [weak self] in self?.setEnabled(false) }
    observer = NotificationCenter.default.addObserver(forName: NativeDesktop.changed, object: desktop, queue: .main) { [weak self] _ in self?.refresh() }
    refresh()
  }
  required init?(coder: NSCoder) { fatalError() }
  private func refresh() {
    toggle.checked = desktop.isEnabled
    restore.isEnabled = desktop.isEnabled || desktop.defaults.bool(forKey: NativeDesktop.preferenceKey)
    status.stringValue = desktop.error; needsLayout = true; onHeightChange?()
  }
  private func setEnabled(_ enabled: Bool) {
    do { try desktop.setEnabled(enabled); refresh() }
    catch { status.stringValue = NL(error.localizedDescription); onHeightChange?() }
  }
  override func layout() {
    super.layout()
    toggle.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - 32), height: 28)
    help.frame = NSRect(x: bounds.width - 24, y: 0, width: 24, height: 28)
    restore.frame = NSRect(x: 0, y: 36, width: min(bounds.width, 240), height: 34)
    status.frame = NSRect(x: 0, y: 76, width: bounds.width, height: 22)
  }
  deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}

final class NativeWakeSettingsView: SurfaceView {
  let preferredHeight: CGFloat = 112
  private let integration: NativeSystemIntegration
  private let wake = EDShortcutRecorder(value: "")
  private let save = NSButton(title: NL("保存快捷键"), target: nil, action: nil)
  private let clear = NSButton(title: NL("清除"), target: nil, action: nil)
  private let status = label("", size: 12)
  init(integration: NativeSystemIntegration) {
    self.integration = integration; super.init(frame: .zero); color = .clear
    [wake, save, clear, status].forEach(addSubview)
    wake.value = integration.wakeShortcut
    wake.captureChanged = { [weak integration] in integration?.captureShortcut($0) }
    wake.onRecord = { [weak self] value in self?.wake.value = value; self?.refresh(); return true }
    wake.onError = { [weak self] in self?.status.stringValue = $0 }
    wake.setAccessibilityLabel(NL("唤醒快捷键")); save.target = self; save.action = #selector(saveWake); clear.target = self; clear.action = #selector(clearWake)
    refresh()
  }
  required init?(coder: NSCoder) { fatalError() }
  private func refresh() {
    status.stringValue = integration.wakeError
    save.isEnabled = wake.value != integration.wakeShortcut || !integration.wakeError.isEmpty
    clear.isEnabled = !wake.value.isEmpty
  }
  @objc private func saveWake() {
    do { try integration.setWakeShortcut(wake.value); wake.value = integration.wakeShortcut; refresh() }
    catch { status.stringValue = NL(error.localizedDescription) }
  }
  @objc private func clearWake() { wake.value = ""; refresh() }
  override func layout() {
    super.layout(); let width = bounds.width
    wake.frame = NSRect(x: 0, y: 0, width: max(100, width - 78), height: 30)
    clear.frame = NSRect(x: max(110, width - 66), y: 0, width: 66, height: 30)
    status.frame = NSRect(x: 0, y: 36, width: width, height: 24)
    save.frame = NSRect(x: 0, y: 70, width: 112, height: 30)
  }
}
