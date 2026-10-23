import AppKit
import ExplorerCore

final class NativeSettingsView: SurfaceView {
  var preferredHeight: CGFloat { status.stringValue.isEmpty ? 34 : 62 }
  var onHeightChange: (() -> Void)?
  private let button = EDButton(title: NL("从 Finder 导入收藏夹"), style: .secondary)
  private let servers = EDButton(title: NL("从 Finder 导入服务器"), style: .secondary)
  private let status = label("", size: 12)
  private let help = NativeHelpButton(text: NL("文件夹合并到快速访问；收藏的 SMB 服务器合并到网络页，不自动连接。"), accessibilityLabel: NL("收藏夹导入说明"))
  init(browser: BrowserController) {
    super.init(frame: .zero); color = .clear
    button.iconName = "folder"
    [button, servers, status, help].forEach(addSubview)
    servers.iconName = "network"
    servers.onPress = { [weak self, weak browser] in
      guard let self, let browser else { return }; self.servers.isEnabled = false; self.button.isEnabled = false; self.setStatus(NL("正在读取…"))
      Task { @MainActor [weak self] in
        do { self?.setStatus(try await browser.importFinderServers()) }
        catch { self?.setStatus(error.localizedDescription) }
        self?.servers.isEnabled = true; self?.button.isEnabled = true
      }
    }
    button.onPress = { [weak self, weak browser] in
      guard let self, let browser else { return }; self.button.isEnabled = false; self.servers.isEnabled = false; self.setStatus(NL("正在读取…"))
      Task { @MainActor [weak self] in
        do { self?.setStatus(try await browser.importFinderFavorites()) }
        catch { self?.setStatus(error.localizedDescription) }
        self?.button.isEnabled = true; self?.servers.isEnabled = true
      }
    }
  }
  required init?(coder: NSCoder) { fatalError() }
  private func setStatus(_ value: String) {
    status.stringValue = value; onHeightChange?()
  }
  override func layout() {
    super.layout(); help.frame = NSRect(x: bounds.width - 24, y: 0, width: 24, height: 34)
    let width = max(0, (bounds.width - 44) / 2)
    button.frame = NSRect(x: 0, y: 0, width: width, height: 34)
    servers.frame = NSRect(x: width + 12, y: 0, width: width, height: 34); status.frame = NSRect(x: 0, y: 40, width: bounds.width, height: 20)
  }
}
