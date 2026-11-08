import AppKit
import ExplorerCore

final class NativeSystemSettingsView: SurfaceView {
  var preferredHeight: CGFloat { 60 + (status.stringValue.isEmpty ? 0 : 30) + (desktopStatus.stringValue.isEmpty ? 0 : 42) }
  var onHeightChange: (() -> Void)?
  private let integration: NativeSystemIntegration
  private let viewer = EDButton(title: NL("使用 Mac Explorer 显示文件"), style: .checkbox)
  private let help = NativeHelpButton(text: NL("使用 Mac Explorer 处理部分系统“在文件夹中显示”请求；关闭后恢复原设置。Finder 仍保留。"), accessibilityLabel: NL("系统文件查看器说明"))
  private let status = label("", size: 12)
  private let desktop = EDButton(title: NL("启用桌面接管"), style: .checkbox)
  private let desktopHelp = NativeHelpButton(text: NL("由 Mac Explorer 显示桌面图标；双击文件夹在本应用打开，文件使用默认应用。关闭或退出后恢复 Finder 桌面。使用静态壁纸，不显示桌面小组件。"), accessibilityLabel: NL("桌面接管说明"))
  private let desktopStatus = label("", size: 12)
  private var desktopObserver: NSObjectProtocol?
  init(integration: NativeSystemIntegration) {
    self.integration = integration; super.init(frame: .zero); color = .clear
    [viewer, help, status, desktop, desktopHelp, desktopStatus].forEach(addSubview)
    viewer.onPress = { [weak self] in self?.toggleViewer() }
    desktop.onPress = { [weak self] in
      guard let self, let service = self.integration.desktop else { return }
      service.setEnabled(!service.enabled)
    }
    if let service = integration.desktop {
      desktopObserver = NotificationCenter.default.addObserver(forName: NativeDesktop.didChange, object: service, queue: .main) { [weak self] _ in self?.refreshDesktop() }
    }
    refreshViewer()
    refreshDesktop()
  }
  deinit { if let desktopObserver { NotificationCenter.default.removeObserver(desktopObserver) } }
  required init?(coder: NSCoder) { fatalError() }
  private func refreshDesktop() {
    desktop.checked = integration.desktop?.enabled ?? false
    desktop.isEnabled = integration.desktop != nil
    desktopStatus.stringValue = integration.desktop?.error ?? ""
    onHeightChange?()
  }
  private func refreshViewer() {
    do { let value = try integration.fileViewer.perform("status"); viewer.checked = value.enabled; viewer.isEnabled = !value.enabled || value.canRestore; if !value.error.isEmpty { status.stringValue = NL(value.error) } }
    catch { viewer.isEnabled = false; status.stringValue = NL(error.localizedDescription) }
  }
  @objc private func toggleViewer() {
    let enabling = !viewer.checked
    let alert = NSAlert(); alert.messageText = enabling ? NL("使用 Mac Explorer 显示文件？") : NL("恢复原文件查看器设置？")
    alert.addButton(withTitle: NL("确定")); alert.addButton(withTitle: NL("取消"))
    guard alert.runModal() == .alertFirstButtonReturn else { refreshViewer(); return }
    do { _ = try integration.fileViewer.perform(enabling ? "enable" : "restore"); status.stringValue = NL("已保存") }
    catch { status.stringValue = NL(error.localizedDescription) }
    refreshViewer(); onHeightChange?()
  }
  override func layout() {
    super.layout(); let width = bounds.width
    viewer.frame = NSRect(x: 0, y: 0, width: width - 32, height: 28); help.frame = NSRect(x: width - 24, y: 0, width: 24, height: 28)
    desktop.frame = NSRect(x: 0, y: 30, width: width - 32, height: 28)
    desktopHelp.frame = NSRect(x: width - 24, y: 30, width: 24, height: 28)
    status.frame = NSRect(x: 0, y: 60, width: width, height: 28); status.maximumNumberOfLines = 2
    desktopStatus.frame = NSRect(x: 0, y: 60 + (status.stringValue.isEmpty ? 0 : 30), width: width, height: 42)
    desktopStatus.maximumNumberOfLines = 2
  }
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
