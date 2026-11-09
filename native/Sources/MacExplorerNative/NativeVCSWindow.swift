import AppKit
import ExplorerCore

@MainActor
final class NativeVCSWindow: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
  private static var openWindows: [UUID: NativeVCSWindow] = [:]
  private let identifier = UUID()
  private let service: NativeVersionControl
  private let directory: URL
  private let paths: [URL]
  private let action: NativeVCSAction
  private let onChanged: () -> Void
  private var plan: NativeVCSPlan?
  private var difference: NativeVCSDiff?
  private var backup: URL?
  private var busy = false
  private var revision = 0
  private let location = NSTextField(wrappingLabelWithString: "")
  private let status = NSTextField(wrappingLabelWithString: "")
  private let output = NSTextView()
  private let message = NSTextView()
  private let messageLabel = NSTextField(labelWithString: NL("提交信息"))
  private let messageScroll = ExplorerScrollView()
  private let tabs = NSSegmentedControl(labels: [NL("未暂存"), NL("已暂存")], trackingMode: .selectOne, target: nil, action: nil)
  private let confirm = NSButton(title: "", target: nil, action: nil)
  private let retry = NSButton(title: NL("重新预览"), target: nil, action: nil)
  private let closeButton = NSButton(title: NL("取消"), target: nil, action: nil)
  private let reveal = NSButton(title: NL("显示备份文件夹"), target: nil, action: nil)

  static func present(service: NativeVersionControl, directory: URL, paths: [URL], action: NativeVCSAction, parent: NSWindow, onChanged: @escaping () -> Void) {
    let controller = NativeVCSWindow(service: service, directory: directory, paths: paths.isEmpty ? [directory] : paths, action: action, onChanged: onChanged)
    openWindows[controller.identifier] = controller
    if let window = controller.window {
      window.appearance = parent.appearance
      let center = NSPoint(x: parent.frame.midX, y: parent.frame.midY)
      window.setFrameOrigin(NSPoint(x: center.x - window.frame.width / 2, y: center.y - window.frame.height / 2))
      parent.addChildWindow(window, ordered: .above)
      controller.showWindow(nil)
      window.makeKeyAndOrderFront(nil)
    }
    controller.load()
  }
  private init(service: NativeVersionControl, directory: URL, paths: [URL], action: NativeVCSAction, onChanged: @escaping () -> Void) {
    self.service = service; self.directory = directory; self.paths = paths; self.action = action; self.onChanged = onChanged
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 550), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = action.title; window.minSize = NSSize(width: 480, height: 420); window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self
    let content = NSView(); window.contentView = content
    let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
    NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)])
    location.stringValue = directory.path; location.font = .systemFont(ofSize: 12); location.textColor = .secondaryLabelColor
    location.setAccessibilityLabel(NL("仓库")); location.maximumNumberOfLines = 2; stack.addArrangedSubview(location)
    tabs.target = self; tabs.action = #selector(changeDiff); tabs.selectedSegment = 0; tabs.isHidden = true; stack.addArrangedSubview(tabs)
    let scroll = ExplorerScrollView(); scroll.borderType = .bezelBorder; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
    output.isEditable = false; output.isSelectable = true; output.font = .monospacedSystemFont(ofSize: 12, weight: .regular); output.isRichText = false
    output.autoresizingMask = [.width]; output.textContainerInset = NSSize(width: 10, height: 10); output.minSize = NSSize(width: 0, height: 0)
    output.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude); output.isVerticallyResizable = true
    output.setAccessibilityLabel(action == .diff ? NL("差异") : NL("此次操作的文件清单"))
    scroll.documentView = output; stack.addArrangedSubview(scroll)
    scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
    stack.addArrangedSubview(messageLabel)
    message.delegate = self; message.isRichText = false; message.font = .systemFont(ofSize: 13); message.textContainerInset = NSSize(width: 6, height: 6)
    message.setAccessibilityLabel(NL("提交信息")); messageScroll.documentView = message; messageScroll.borderType = .bezelBorder; messageScroll.hasVerticalScroller = true
    stack.addArrangedSubview(messageScroll); messageScroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true; messageScroll.heightAnchor.constraint(equalToConstant: 70).isActive = true
    messageScroll.isHidden = action != .commit; messageLabel.isHidden = action != .commit
    status.font = .systemFont(ofSize: 12); status.maximumNumberOfLines = 4; status.setAccessibilityLabel(NL("状态")); stack.addArrangedSubview(status)
    let actions = NSStackView(); actions.orientation = .horizontal; actions.spacing = 8
    reveal.target = self; reveal.action = #selector(revealBackup); reveal.isHidden = true
    retry.target = self; retry.action = #selector(reload); retry.isHidden = true
    closeButton.target = self; closeButton.action = #selector(dismiss); closeButton.keyEquivalent = "\u{1b}"
    confirm.title = action == .revert ? NL("备份并丢弃修改") : action == .commit ? NL("确认提交") : action == .update ? NL("确认更新") : NL("确认加入")
    confirm.target = self; confirm.action = #selector(execute); confirm.bezelStyle = .rounded; confirm.isHidden = true
    [reveal, retry, closeButton, confirm].forEach { actions.addArrangedSubview($0) }
    stack.addArrangedSubview(actions); actions.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  private func load() {
    guard !busy else { return }
    revision += 1; let loadRevision = revision
    plan = nil; difference = nil; backup = nil; confirm.isHidden = true; reveal.isHidden = true; retry.isHidden = true; tabs.isHidden = true
    status.textColor = .secondaryLabelColor; status.stringValue = NL("正在读取版本状态…"); output.string = ""
    let service = service, directory = directory, paths = paths, action = action
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let result: Result<(NativeVCSPlan?, NativeVCSDiff?), Error> = Result {
        if action == .diff { return (nil, try service.diff(directory: directory, paths: paths)) }
        return (try service.prepare(directory: directory, action: action, paths: paths), nil)
      }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.revision == loadRevision, self.window?.isVisible == true else { return }
        switch result {
        case .success(let value):
          self.plan = value.0; self.difference = value.1; self.status.stringValue = ""
          if let plan = value.0 {
            self.location.stringValue = plan.root.path
            self.output.string = plan.changes.map { change in
              let staging = plan.kind == .git ? (change.staged && change.unstaged ? NL("已暂存及未暂存") : change.staged ? NL("已暂存") : NL("未暂存")) : change.state.title
              return "\(change.state.mark)  \(change.path)  ·  \(staging)"
            }.joined(separator: "\n")
            if plan.action == .update { self.output.string = plan.kind == .git ? NL("更新整个仓库 · 仅快进") : NL("更新整个工作副本 · 保留冲突") }
            if plan.action == .commit && plan.kind == .git { self.status.stringValue = NL("提交整个仓库的已暂存内容") }
            if plan.action == .revert { self.status.stringValue = plan.kind == .git ? NL("恢复至暂存区 · 保留未跟踪文件") : NL("恢复本地内容及属性 · 保留未跟踪文件") }
            self.confirm.isHidden = false; self.textDidChange(Notification(name: NSText.didChangeNotification))
            if plan.action == .commit { self.window?.makeFirstResponder(self.message) }
          }
          if let diff = value.1 { self.tabs.isHidden = diff.kind == .svn; self.tabs.selectedSegment = diff.working.isEmpty && !diff.staged.isEmpty ? 1 : 0; self.changeDiff() }
        case .failure(let error): self.show(error)
        }
      }
    }
  }
  @objc private func changeDiff() {
    guard let difference else { return }
    let value = tabs.selectedSegment == 1 ? difference.staged : difference.working
    let lines = value.components(separatedBy: "\n")
    output.string = value.isEmpty ? NL("没有可显示的差异") : lines.prefix(3000).joined(separator: "\n")
    status.stringValue = lines.count > 3000 ? NL("仅显示前 3,000 行差异") : ""
    closeButton.title = NL("关闭")
  }
  private func show(_ error: Error) {
    status.textColor = .systemRed; status.stringValue = String(error.localizedDescription.prefix(3000)); retry.isHidden = !service.isEnabled; confirm.isHidden = true
  }
  @objc private func reload() { load() }
  @objc private func execute() {
    guard !busy, let plan else { return }
    let text = message.string
    if action == .commit && (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 10_000) { show(NSError(domain: "NativeVCS", code: 1, userInfo: [NSLocalizedDescriptionKey: NL("请填写有效的提交信息。") ])); return }
    busy = true; closeButton.isEnabled = false; confirm.isEnabled = false; retry.isHidden = true; message.isEditable = false
    status.textColor = .secondaryLabelColor; status.stringValue = NL("正在处理…")
    let service = service
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let result = Result { try service.execute(id: plan.id, message: text) }
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.busy = false; self.closeButton.isEnabled = true; self.confirm.isEnabled = true; self.message.isEditable = true
        self.plan = nil; self.confirm.isHidden = true; self.closeButton.title = NL("关闭")
        switch result {
        case .success(let value):
          self.status.stringValue = NL("操作已完成。"); self.output.string = value.output
          self.backup = value.backup; self.reveal.isHidden = value.backup == nil
          if let backup = value.backup { self.output.string += "\n" + NL("修改前的文件备份保存在：{0}", backup.path) }
        case .failure(let error): self.show(error)
        }
        self.onChanged()
      }
    }
  }
  func textDidChange(_ notification: Notification) {
    confirm.isEnabled = !busy && (action != .commit || !message.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && message.string.count <= 10_000)
  }
  @objc private func revealBackup() { if let backup { NSWorkspace.shared.activateFileViewerSelecting([backup]) } }
  @objc private func dismiss() { if !busy { close() } }
  func windowShouldClose(_ sender: NSWindow) -> Bool { !busy }
  func windowWillClose(_ notification: Notification) {
    revision += 1
    if let window { window.parent?.removeChildWindow(window) }
    Self.openWindows.removeValue(forKey: identifier)
  }
}
