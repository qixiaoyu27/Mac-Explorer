import AppKit
import ExplorerCore
import Quartz

@MainActor
enum NativeSmoke {
  struct Failure: Error, CustomStringConvertible { let description: String }

  static func run(browser: BrowserController, window: NSWindow, root: URL, report: URL) async {
    var checks: [String] = []
    var metrics: [String: Any] = [:]
    func expect(_ condition: Bool, _ name: String) throws {
      guard condition else { throw Failure(description: name) }
      checks.append(name)
    }
    do {
      if let index = CommandLine.arguments.firstIndex(of: "--quit-session-suite"), CommandLine.arguments.indices.contains(index + 1) {
        try await NativeQuitChecks.child(browser: browser, window: window, root: root, suite: CommandLine.arguments[index + 1], report: report)
        return
      }
      if let index = CommandLine.arguments.firstIndex(of: "--column-settings"), CommandLine.arguments.indices.contains(index + 1) {
        checks += try await NativeColumnChecks.restore(root: root, suite: CommandLine.arguments[index + 1], window: window)
        try write(["passed": true, "checks": checks], to: report); NSApp.terminate(nil); return
      }
      if ProcessInfo.processInfo.arguments.contains("--smoke-file-parity") {
        checks += try await NativeColumnChecks.run(output: report.deletingLastPathComponent())
        checks += try await NativeNetworkDeleteChecks.run(output: report.deletingLastPathComponent())
        checks += try await NativeHistoryPropertiesChecks.run(output: report.deletingLastPathComponent())
        try write(["passed": true, "checks": checks], to: report); NSApp.terminate(nil); return
      }
      if ProcessInfo.processInfo.arguments.contains("--smoke-navigation-state") {
        checks += try await NativeNavigationStateChecks.run()
        try write(["passed": true, "checks": checks], to: report)
        NSApp.terminate(nil); return
      }
      if ProcessInfo.processInfo.arguments.contains("--smoke-vcs-edit") {
        checks += try await NativeVCSEditingChecks.run()
        try write(["passed": true, "checks": checks], to: report)
        NSApp.terminate(nil); return
      }
      if let index = CommandLine.arguments.firstIndex(of: "--start-location-settings"), CommandLine.arguments.indices.contains(index + 1) {
        let restored = try await NativeStartLocationChecks.restore(root: root, suite: CommandLine.arguments[index + 1], window: window)
        try write(["passed": true, "checks": restored], to: report); NSApp.terminate(nil); return
      }
      if ProcessInfo.processInfo.arguments.contains("--smoke-integrations") {
        checks += try await NativeTerminalChecks.run(browser: browser, output: report.deletingLastPathComponent())
        checks += try await NativeAirDropUIChecks.run()
        try write(["passed": true, "checks": checks, "fixtureDevices": true], to: report)
        NSApp.terminate(nil); return
      }
      if let index = CommandLine.arguments.firstIndex(of: "--created-date-settings"), CommandLine.arguments.indices.contains(index + 1) {
        let restored = try await NativeCreatedDateChecks.restore(root: root, suite: CommandLine.arguments[index + 1], window: window)
        try write(["passed": true, "checks": restored], to: report); NSApp.terminate(nil); return
      }
      if ProcessInfo.processInfo.arguments.contains("--smoke-airdrop") {
        checks += try await NativeAirDropUIChecks.run()
        try write(["passed": true, "checks": checks, "fixtureDevices": true], to: report)
        NSApp.terminate(nil); return
      }
      try await until { !browser.loading && browser.snapshot != nil && browser.entries.count == 10_003 }
      window.contentView?.layoutSubtreeIfNeeded()
      checks += try await NativeInputNavigationChecks.runBrowser(browser: browser, window: window)
      try expect(!browser.content.hasAmbiguousLayout && browser.content.bounds.height > 300, "file area has a non-ambiguous usable layout")
      try await until { IconLoader.shared.isIdle && IconLoader.shared.loads > 0 }
      try expect(browser.table.numberOfRows == 10_003, "10,003 visible fixture entries loaded")
      let visible = browser.table.rows(in: browser.table.visibleRect)
      var allocatedRows = 0
      browser.table.enumerateAvailableRowViews { _, _ in allocatedRows += 1 }
      try expect(allocatedRows < 150 && visible.length > 0, "table instantiates viewport rows, not the full directory")
      metrics["entries"] = browser.entries.count
      metrics["tableInstantiatedRows"] = allocatedRows
      metrics["directoryReadMilliseconds"] = browser.snapshot!.elapsedMilliseconds
      metrics["loadToTableUpdateMilliseconds"] = browser.displayedMilliseconds
      metrics["iconLoadsAfterInitialListing"] = IconLoader.shared.loads
      try expect(IconLoader.shared.loads < 150, "initial icon requests are bounded by visible rows")
      try expect(browser.entries.first?.isDirectory == true, "folders precede files")
      try expect(!browser.entries.contains { $0.name == ".hidden-fixture" }, "hidden entries excluded initially")
      browser.table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
      try expect(browser.selectedPaths.count == 2, "native table multi-selection updates the model")
      let selected = browser.selectedPaths
      browser.iconMode = true; browser.updateMode()
      try await until { !browser.collection.visibleItems().isEmpty && IconLoader.shared.isIdle }
      try expect(browser.selectedPaths == selected && browser.collection.selectionIndexPaths.count == 2, "selection survives details-to-icons switch")
      try expect(browser.collection.visibleItems().count < 150, "collection reuses visible items")
      let menu = browser.viewMenu()
      try expect(menu.map(\.title) == ["超大图标", "大图标", "中图标", "小图标", "列表", "详细信息", "平铺", "内容", "列", "详细信息窗格", "预览窗格", "显示", "应用到所有文件夹"], "View menu preserves layout order and includes column customization")
      for index in [0, 1, 2, 3, 4, 6, 7] {
        menu[index].action?()
        window.contentView?.layoutSubtreeIfNeeded()
        try await until { !browser.collection.visibleItems().isEmpty }
        try expect(browser.collection.visibleItems().count < 150 && browser.selectedPaths == selected, "\(menu[index].title) preserves selection and bounded cells")
      }
      menu[5].action?()
      try expect(browser.mode == .details && browser.table.selectedRowIndexes.count == 2, "details menu restores the native table and selection")
      browser.previewButton.performClick(nil)
      window.contentView?.layoutSubtreeIfNeeded()
      try expect(browser.paneMode == "preview" && browser.pane.bounds.width == 276, "preview command opens the matching-width pane")
      let paneScroll = browser.pane.subviews.compactMap { $0 as? NSScrollView }.first
      try expect(browser.pane.leftBorder && paneScroll?.frame.minX == 1 && paneScroll?.frame.maxX == browser.pane.bounds.maxX, "pane content leaves the full-height divider uncovered")
      for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
        NSApp.appearance = NSAppearance(named: appearance)
        try capture(window, at: report.deletingLastPathComponent().appendingPathComponent("native-preview-\(name).png"))
      }
      NSApp.appearance = NSAppearance(named: .aqua)
      menu.first { $0.title == NL("详细信息窗格") }?.action?()
      try expect(browser.paneMode == "details", "details and preview panes are mutually exclusive")
      menu.first { $0.title == NL("详细信息窗格") }?.action?()
      let show = menu.first { $0.title == NL("显示") }!.children
      show[1].action?()
      try expect(browser.table.rowHeight == 28, "compact view uses 28-point rows")
      show[1].action?()
      show[2].action?()
      try expect(browser.checkboxes, "Show menu enables item checkboxes")
      show[2].action?()
      show[3].action?()
      try expect(!browser.extensions, "Show menu toggles file extensions")
      show[3].action?()
      browser.setView(.icons, size: 64)
      try await until { IconLoader.shared.isIdle }
      metrics["collectionVisibleItems"] = browser.collection.visibleItems().count
      try capture(window, at: report.deletingLastPathComponent().appendingPathComponent("native-icons.png"))
      browser.iconMode = false; browser.updateMode()
      browser.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
      window.makeFirstResponder(browser.table)
      if let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: String(UnicodeScalar(NSDownArrowFunctionKey)!), charactersIgnoringModifiers: String(UnicodeScalar(NSDownArrowFunctionKey)!), isARepeat: false, keyCode: 125) {
        browser.table.keyDown(with: down)
      }
      try expect(browser.table.selectedRow == 1, "native arrow-key selection moves to the next row")
      browser.search.stringValue = "file-9999"; browser.recompute()
      try await until { browser.entries.count == 1 && browser.entries[0].name == "file-9999.txt" }
      try expect(browser.table.numberOfRows == 1, "current-folder filtering updates the native table")
      browser.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
      browser.previewSelected()
      try await until { QLPreviewPanel.shared()?.isVisible == true }
      try expect(browser.numberOfPreviewItems(in: QLPreviewPanel.shared()) == 1, "Quick Look opens the selected fixture file")
      QLPreviewPanel.shared()?.orderOut(nil)
      window.makeKeyAndOrderFront(nil)
      browser.search.stringValue = "no-such-fixture"; browser.recompute()
      try await until { browser.entries.isEmpty && !browser.emptyLabel.isHidden }
      try expect(browser.emptyLabel.stringValue == "没有匹配的项目", "empty filter result is explicit")
      browser.search.stringValue = ""; browser.toggleHidden()
      try await until { browser.entries.count == 10_004 }
      try expect(browser.entries.contains { $0.name == ".hidden-fixture" }, "hidden toggle reveals hidden entry")
      browser.toggleHidden()
      try await until { browser.entries.count == 10_003 }
      browser.search.stringValue = "child.txt"
      if let action = browser.search.action { browser.search.sendAction(action, to: browser.search.target) }
      try await until { !browser.loading && browser.entries.count == 1 && browser.entries[0].name == "child.txt" }
      try expect(browser.entries[0].url.deletingLastPathComponent().lastPathComponent == "Folder 2", "search submission searches descendants without following folder links")
      browser.search.stringValue = ""; browser.searchBox.onClear?()
      try await until { !browser.loading && browser.entries.count == 10_003 }
      func chooseSort(_ title: String) throws {
        guard let action = browser.sortMenu().first(where: { $0.title == NL(title) })?.action else { throw Failure(description: "Missing sort menu action: " + title) }
        action()
      }
      try chooseSort("名称"); try chooseSort("递减")
      try await until { browser.entries.last?.name == "file-0.txt" }
      try expect(browser.entries.first?.isDirectory == true, "descending sorting retains folders first")
      try chooseSort("递增")
      try await until { browser.entries.first?.name == "Folder 2" }
      let folderRow = browser.entries.firstIndex { $0.name == "Folder 2" }!
      browser.table.selectRowIndexes(IndexSet(integer: folderRow), byExtendingSelection: false)
      browser.openSelected()
      try await until { !browser.loading && browser.directory.lastPathComponent == "Folder 2" && browser.snapshot != nil }
      try expect(browser.entries.count == 1 && browser.entries[0].name == "child.txt", "opening a folder loads its children")
      browser.back()
      try await until { !browser.loading && browser.directory == root && browser.entries.count == 10_003 }
      browser.forward()
      try await until { !browser.loading && browser.directory.lastPathComponent == "Folder 2" && browser.entries.count == 1 }
      try expect(browser.entries[0].name == "child.txt", "back/forward history restores directories")
      browser.newTab()
      try await until { !browser.loading && browser.tabs.count == 2 }
      browser.navigate(to: root)
      try await until { !browser.loading && browser.entries.count == 10_003 }
      browser.switchTab(to: 0)
      try await until { !browser.loading && browser.entries.count == 1 }
      try expect(browser.directory.lastPathComponent == "Folder 2", "tabs maintain independent directory history")
      browser.closeTab()
      try await until { !browser.loading && browser.tabs.count == 1 && browser.entries.count == 10_003 }
      browser.navigate(to: root.appendingPathComponent("missing"))
      try await until { !browser.loading && browser.lastError != nil }
      try expect(browser.entries.isEmpty && !browser.emptyLabel.isHidden, "missing directory shows an error, not stale rows")
      browser.navigate(to: root)
      browser.navigate(to: root.appendingPathComponent("Folder 2"))
      try await until { !browser.loading && browser.entries.count == 1 }
      try expect(browser.snapshot?.directory.lastPathComponent == "Folder 2", "rapid navigation rejects stale directory results")
      browser.navigate(to: root.appendingPathComponent("Folder 10"))
      try await until { !browser.loading && browser.snapshot != nil }
      try expect(browser.entries.isEmpty && browser.emptyLabel.stringValue == "此文件夹为空", "empty directory has a distinct empty state")
      browser.navigate(to: root)
      try await until { !browser.loading && browser.entries.count == 10_003 }
      browser.table.scrollRowToVisible(9_500)
      window.contentView?.layoutSubtreeIfNeeded()
      try await until { browser.table.rows(in: browser.table.visibleRect).location > 9_000 }
      try expect(browser.table.rows(in: browser.table.visibleRect).length < 100, "large-directory scroll keeps a bounded viewport")
      browser.table.scrollRowToVisible(0)
      NSApp.appearance = NSAppearance(named: .aqua)
      try await Task.sleep(nanoseconds: 120_000_000)
      try capture(window, at: report.deletingLastPathComponent().appendingPathComponent("native-details.png"))
      NSApp.appearance = NSAppearance(named: .darkAqua)
      try await Task.sleep(nanoseconds: 120_000_000)
      try capture(window, at: report.deletingLastPathComponent().appendingPathComponent("native-dark.png"))
      try expect(true, "light and dark window snapshots captured")
      NSApp.appearance = NSAppearance(named: .aqua)
      window.setContentSize(NSSize(width: 920, height: 540))
      try await Task.sleep(nanoseconds: 100_000_000)
      window.contentView?.layoutSubtreeIfNeeded()
      try expect(browser.content.bounds.height > 300 && browser.address.bounds.width > 250, "compact window preserves navigation and usable file area")
      try capture(window, at: report.deletingLastPathComponent().appendingPathComponent("native-compact.png"))
      NSApp.appearance = nil
      checks += try await NativeParityChecks.run(source: browser, output: report.deletingLastPathComponent())
      checks += try await exerciseOperations(browser: browser, window: window)
      checks += try await NativeInteractionChecks.run(source: browser, output: report.deletingLastPathComponent())
      checks += try await NativeLatestChecks.run(parent: window)
      checks += try await NativeFinderServersChecks.run(output: report.deletingLastPathComponent())
      checks += try await NativeQuitChecks.run(output: report.deletingLastPathComponent())
      checks += try await NativeNavigationStateChecks.run()
      checks += try await NativeColumnChecks.run(output: report.deletingLastPathComponent())
      checks += try await NativeNetworkDeleteChecks.run(output: report.deletingLastPathComponent())
      checks += try await NativeLifecycleChecks.run(source: browser)
      checks += try await NativeStartLocationChecks.run(output: report.deletingLastPathComponent())
      checks += try await NativeVCSUIChecks.run(parent: window)
      checks += try await NativeVCSEditingChecks.run()
      checks += try await NativePaneChecks.run()
      checks += try await NativeCreatedDateChecks.run(output: report.deletingLastPathComponent())
      checks += try await NativeHistoryPropertiesChecks.run(output: report.deletingLastPathComponent())
      checks += try await NativeClipboardChecks.run()
      checks += try await NativeTransferPanelChecks.run()
      checks += try await NativeSMBTransferChecks.run(output: report.deletingLastPathComponent())
      checks += try await NativeLanguageChecks.run()
      checks += try await NativeAddressTabChecks.run(source: browser)
      checks += try await NativeVolumeChecks.run(output: report.deletingLastPathComponent())
      checks += try NativeShortcutChecks.run()
      checks += try await NativePrivacyChecks.run()
      checks += try await NativeTerminalChecks.run(browser: browser, output: report.deletingLastPathComponent())
      checks += try await NativeAirDropUIChecks.run()
      browser.navigate(to: root)
      try await until { !browser.loading && browser.entries.count == 10_003 }
      metrics["iconLoadsAfterAllInteractions"] = IconLoader.shared.loads
      try write(["passed": true, "checks": checks, "metrics": metrics], to: report)
      NSApp.terminate(nil)
    } catch {
      try? capture(window, at: report.deletingLastPathComponent().appendingPathComponent("native-failure.png"))
      try? write(["passed": false, "checks": checks, "metrics": metrics, "error": String(describing: error)], to: report)
      fputs("Native smoke failed: \(error)\n", stderr)
      exit(1)
    }
  }

  static func compare(browser: BrowserController, window: NSWindow, root: URL, report: URL) async {
    do {
      let fixture = root.deletingLastPathComponent()
      guard root.lastPathComponent == "Documents", fixture.lastPathComponent.hasPrefix("explorer-reference-"), fixture.deletingLastPathComponent().resolvingSymlinksInPath() == FileManager.default.temporaryDirectory.resolvingSymlinksInPath() else { throw Failure(description: "Comparison requires the temporary fixture created by reference.mjs") }
      try await until { !browser.loading && browser.snapshot != nil && !browser.entries.isEmpty }
      try await until { IconLoader.shared.isIdle }
      let output = report.deletingLastPathComponent()
      browser.setView(.details)
      try await Task.sleep(nanoseconds: 250_000_000)
      try capture(window, at: output.appendingPathComponent("native-details.png"))
      browser.viewButton.performClick(nil)
      try await Task.sleep(nanoseconds: 100_000_000)
      if let panel = window.childWindows?.first { try capture(panel, at: output.appendingPathComponent("native-view-menu.png")) }
      ExplorerMenu.dismiss()
      var layouts: [[String: Any]] = []
      for (name, mode, size) in [("extra", ExplorerLayoutMode.icons, 128.0), ("icons", .icons, 64.0), ("medium", .icons, 48.0), ("small", .icons, 32.0), ("list", .list, 22.0), ("tiles", .tiles, 48.0), ("content", .content, 56.0)] {
        browser.setView(mode, size: size)
        window.contentView?.layoutSubtreeIfNeeded()
        try await until { !browser.collection.visibleItems().isEmpty && IconLoader.shared.isIdle }
        try await Task.sleep(nanoseconds: 100_000_000)
        try capture(window, at: output.appendingPathComponent("native-\(name).png"))
        layouts.append(["mode": name, "visibleItems": browser.collection.visibleItems().count])
      }
      browser.setView(.details)
      NSApp.appearance = NSAppearance(named: .darkAqua)
      try await Task.sleep(nanoseconds: 150_000_000)
      try capture(window, at: output.appendingPathComponent("native-dark.png"))
      NSApp.appearance = NSAppearance(named: .aqua)
      browser.executeAction("settings")
      try await until { modalWindows(window).count == 2 }
      try capture(window, at: output.appendingPathComponent("native-settings.png"))
      for modal in modalWindows(window) { modal.contentView?.layoutSubtreeIfNeeded() }
      guard let light = dialogButtons(window).first(where: { $0.title == "浅色" }),
            let scroll = light.enclosingScrollView, let document = scroll.documentView,
            scroll.contentView.bounds.minY == 0,
            light.convert(light.bounds, to: document).minY >= 20,
            light.visibleRect.contains(light.bounds)
      else { throw Failure(description: "Settings must open at the top with the appearance controls fully visible: \(dialogButtons(window).filter { $0.title == "浅色" }.map { "frame=\($0.frame), visible=\($0.visibleRect), scroll=\(String(describing: $0.enclosingScrollView?.contentView.bounds))" })") }
      let settingsWindows = modalWindows(window)
      let appearances = settingsWindows.map(\.appearance)
      settingsWindows.forEach { $0.appearance = NSAppearance(named: .darkAqua) }
      try capture(window, at: output.appendingPathComponent("native-settings-dark.png"))
      for (modal, appearance) in zip(settingsWindows, appearances) { modal.appearance = appearance }

      for (title, file) in [("自定义工具栏", "native-settings-toolbar.png"), ("键盘快捷键", "native-settings-shortcuts.png"), ("关于", "native-settings-about.png")] {
        guard let button = dialogButtons(window).first(where: { $0.title == title }) else { throw Failure(description: "Missing settings tab: \(title)") }
        button.performClick(nil); try await Task.sleep(nanoseconds: 100_000_000)
        if title == "关于" {
          let text = dialogText(window).joined(separator: "\n")
          guard text.contains("尚未检查更新"), text.contains("GPL-3.0-only"), !text.contains("当前版本："),
                ["项目主页", "GitHub 发布页", "问题反馈", "开源许可", "检查更新"].allSatisfy({ title in dialogButtons(window).contains { $0.title == title } })
          else { throw Failure(description: "About page is missing migrated content") }
        }
        try capture(window, at: output.appendingPathComponent(file))
      }
      try write(["passed": true, "checks": ["Settings opens at the top with fully visible appearance controls", "Light and dark settings screenshots captured", "All four settings tabs render"]], to: output.appendingPathComponent("settings-report.json"))
      try dismissDialog(window)
      browser.setView(.details)
      browser.executeAction("new-folder")
      try await until {
        guard !browser.loading, let index = browser.entries.firstIndex(where: { $0.name == "新建文件夹" }), let cell = browser.table.view(atColumn: 0, row: index, makeIfNecessary: false) as? NameCell else { return false }
        return cell.nameLabel.isEditable
      }
      try capture(window, at: output.appendingPathComponent("native-new-folder.png"))
      window.makeFirstResponder(browser.table)
      browser.executeAction("undo")
      try await until { !browser.loading && !browser.entries.contains(where: { $0.name == "新建文件夹" }) }
      browser.table.selectRowIndexes(IndexSet(integer: min(3, browser.entries.count - 1)), byExtendingSelection: false)
      browser.executeAction("properties")
      try await until { modalWindows(window).count == 2 }
      try await until { dialogText(window).contains("占用空间") }
      try capture(window, at: output.appendingPathComponent("native-properties.png")); try dismissDialog(window)
      let areas: [String: NSView] = [".tab-strip": browser.tabsBar, ".navigation-bar": browser.navigationBar, ".command-bar": browser.commandBar, ".sidebar": browser.sidebar, ".file-content": browser.content, ".status-bar": browser.footer, ".address-bar": browser.addressBar, ".search-box": browser.searchBox]
      let geometry = areas.mapValues { area in let rect = area.convert(area.bounds, to: browser.view); return ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height] }
      if let index = browser.entries.firstIndex(where: { $0.name == "产品需求.md" }) {
        browser.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        browser.executeAction("details-pane")
        try await Task.sleep(nanoseconds: 300_000_000)
        try capture(window, at: output.appendingPathComponent("native-details-pane.png"))
        browser.executeAction("details-pane")
        let items = browser.contextItems(), quickNames = ["剪切", "复制", "重命名", "移到回收站"]
        ExplorerMenu.show(items.filter { !quickNames.contains($0.title) }, at: NSPoint(x: window.frame.midX, y: window.frame.midY + 180), owner: window, quickActions: quickNames.compactMap { name in items.first { $0.title == name } })
        try capture(window, at: output.appendingPathComponent("native-context.png")); ExplorerMenu.dismiss()
      }
      let appItems = ["Finder（默认）", "Visual Studio Code", "Books", "ChatGPT", "Mac Explorer", "选择其他应用"].map { ExplorerMenuItem(title: $0, icon: "applications") }
      let appWidth = ExplorerMenu.fittedWidth(appItems, submenu: true)
      guard appWidth >= 180 && appWidth < 230,
            ExplorerMenu.fittedWidth([ExplorerMenuItem(title: "复制", shortcut: "⌃⌥⇧⌘C")], submenu: true) >= 180 else { throw Failure(description: "Submenu must fit measured labels and shortcuts") }
      ExplorerMenu.show([ExplorerMenuItem(title: "打开方式", children: appItems)], at: NSPoint(x: window.frame.midX, y: window.frame.midY + 180), owner: window)
      if let menu = window.childWindows?.last, let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: menu.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125) { NSApp.sendEvent(down) }
      try await Task.sleep(nanoseconds: 100_000_000)
      guard window.childWindows?.contains(where: { abs($0.frame.width - appWidth) < 0.5 }) == true else { throw Failure(description: "Open With submenu uses measured width") }
      try capture(window, at: output.appendingPathComponent("native-open-with-width.png")); ExplorerMenu.dismiss()
      browser.navigate(to: URL(string: "explorer://network")!)
      browser.search.stringValue = "no-such-network-parity-fixture"
      browser.search.sendAction(browser.search.action, to: browser.search.target)
      try await Task.sleep(nanoseconds: 5_500_000_000)
      try capture(window, at: output.appendingPathComponent("native-network.png"))
      browser.navigate(to: URL(string: "explorer://airdrop")!)
      try capture(window, at: output.appendingPathComponent("native-airdrop.png"))
      browser.navigate(to: root)
      try await until { !browser.loading && !browser.entries.isEmpty }
      window.setFrame(NSRect(x: window.frame.minX, y: window.frame.minY, width: 800, height: 530), display: true)
      window.contentView?.layoutSubtreeIfNeeded()
      try await Task.sleep(nanoseconds: 100_000_000)
      guard browser.moreButton.frame.maxX <= browser.previewButton.frame.minX, browser.addressBar.frame.width >= 100 else { throw Failure(description: "Commands or address overlap at minimum window size") }
      try capture(window, at: output.appendingPathComponent("native-minimum.png"))
      browser.viewButton.performClick(nil)
      try await Task.sleep(nanoseconds: 100_000_000)
      let viewport = window.convertToScreen(browser.view.convert(browser.view.bounds, to: nil))
      guard let menu = window.childWindows?.first, viewport.contains(menu.frame) else { throw Failure(description: "View menu escapes the minimum-size window") }
      try capture(window, at: output.appendingPathComponent("native-minimum-menu.png")); ExplorerMenu.dismiss()
      try write(["passed": true, "layouts": layouts, "geometry": geometry, "entries": browser.entries.count, "minimumWindow": "800x530"], to: report)
      NSApp.terminate(nil)
    } catch { try? write(["passed": false, "error": String(describing: error)], to: report); fputs("Comparison failed: \(error)\n", stderr); exit(1) }
  }

  private static func exerciseOperations(browser: BrowserController, window: NSWindow) async throws -> [String] {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("native-ui-actions-\(UUID().uuidString)")
    let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination"), trash = root.appendingPathComponent("trash")
    for url in [source, destination, trash] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
    defer { browser.testTrashDirectory = nil; try? fm.removeItem(at: root) }
    browser.testTrashDirectory = trash
    let original = source.appendingPathComponent("original.txt"), payload = Data("preserve source".utf8)
    try payload.write(to: original)
    var checks: [String] = []
    func check(_ condition: Bool, _ name: String) throws { guard condition else { throw Failure(description: name) }; checks.append(name) }
    func select(_ name: String) throws {
      guard let row = browser.entries.firstIndex(where: { $0.name == name }) else { throw Failure(description: "Missing UI fixture: \(name)") }
      browser.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }
    func textField(_ name: String) -> NSTextField? {
      guard let row = browser.entries.firstIndex(where: { $0.name == name }) else { return nil }
      return (browser.table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NameCell)?.nameLabel
    }
    browser.navigate(to: source)
    try await until { !browser.loading && browser.entries.count == 1 }
    browser.setView(.details)
    browser.executeAction("new-folder")
    try await until { !browser.busy && !browser.loading && textField("新建文件夹")?.isEditable == true }
    try check(modalWindows(window).isEmpty, "New folder enters inline rename rather than opening a dialog")
    guard let field = textField("新建文件夹"), let action = field.action else { throw Failure(description: "No inline rename field") }
    field.currentEditor()?.string = "Renamed folder"; field.stringValue = "Renamed folder"; field.sendAction(action, to: field.target)
    try await until { !browser.busy && !browser.loading && browser.entries.contains { $0.name == "Renamed folder" } }
    try check(fm.fileExists(atPath: source.appendingPathComponent("Renamed folder").path), "Inline rename commits the actual folder")
    browser.executeAction("undo")
    try await until { !browser.busy && !browser.loading && browser.entries.contains { $0.name == "新建文件夹" } }
    browser.executeAction("undo")
    try await until { !browser.busy && !browser.loading && browser.entries.count == 1 }
    try check((try fm.contentsOfDirectory(atPath: trash.path)).count == 1, "Undo creation uses isolated Trash")
    try select("original.txt"); browser.executeAction("copy")
    browser.navigate(to: destination)
    try await until { !browser.loading && browser.snapshot != nil }
    browser.setView(.details); browser.executeAction("paste")
    try await until { !browser.busy && !browser.loading && browser.entries.contains { $0.name == "original.txt" } }
    try check(try Data(contentsOf: original) == payload && Data(contentsOf: destination.appendingPathComponent("original.txt")) == payload, "UI copy/paste preserves source and contents")
    browser.executeAction("paste")
    try await until { !browser.busy && !browser.loading }
    try check(try Data(contentsOf: destination.appendingPathComponent("original.txt")) == payload, "Repeated paste refuses an overwrite")
    try select("original.txt"); browser.executeAction("rename")
    guard let rename = textField("original.txt"), let renameAction = rename.action else { throw Failure(description: "Rename command did not start an editor") }
    rename.currentEditor()?.string = "moved.txt"; rename.stringValue = "moved.txt"; rename.sendAction(renameAction, to: rename.target)
    try await until { !browser.busy && !browser.loading && browser.entries.contains { $0.name == "moved.txt" } }
    try select("moved.txt"); browser.executeAction("cut"); browser.navigate(to: source)
    try await until { !browser.loading && browser.entries.count == 1 }
    browser.setView(.details); browser.executeAction("paste")
    try await until { !browser.busy && !browser.loading && browser.entries.count == 2 }
    try check(!fm.fileExists(atPath: destination.appendingPathComponent("moved.txt").path), "Cut/paste moves the selected fixture")
    try select("moved.txt"); browser.executeAction("trash")
    try await until { ExplorerDialogs.isPresenting(in: window) }
    try check(browser.validateMenuItem(NSMenuItem(title: "New tab", action: #selector(BrowserController.newTab), keyEquivalent: "t")) == false, "File dialog blocks background menu actions")
    guard let confirm = dialogButtons(window).first(where: { $0.title == "移到回收站" }) else { throw Failure(description: "Missing Trash confirmation") }
    confirm.performClick(nil)
    try await until { !browser.busy && !browser.loading && browser.entries.count == 1 }
    browser.executeAction("undo")
    try await until { !browser.busy && !browser.loading && browser.entries.count == 2 }
    try check(try Data(contentsOf: source.appendingPathComponent("moved.txt")) == payload, "Trash confirmation and undo restore the fixture")
    try check(try Data(contentsOf: original) == payload, "UI operation sequence preserves the original file")
    return checks
  }

  private static func modalWindows(_ window: NSWindow) -> [NSWindow] {
    (window.childWindows ?? []).flatMap { [$0] + modalWindows($0) }
  }
  private static func dialogText(_ window: NSWindow) -> [String] {
    func text(_ view: NSView) -> [String] { (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(text) }
    return modalWindows(window).compactMap(\.contentView).flatMap(text)
  }
  private static func dialogButtons(_ window: NSWindow) -> [NSButton] {
    func buttons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
    return modalWindows(window).reversed().compactMap(\.contentView).flatMap(buttons).filter { !$0.isHiddenOrHasHiddenAncestor }
  }
  private static func dismissDialog(_ window: NSWindow) throws {
    guard let button = dialogButtons(window).first(where: { $0.title == "取消" || $0.title == "关闭" }) else { throw Failure(description: "No dialog dismissal button") }
    button.performClick(nil)
  }

  static func until(_ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(20)
    while !predicate() {
      if Date() > deadline { throw Failure(description: "Timed out waiting for native UI state") }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
  }
  private static func capture(_ window: NSWindow, at url: URL) throws {
    guard let view = window.contentView else { throw Failure(description: "No window content") }
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure(description: "Cannot capture window content") }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    var result = bitmap
    let children = modalWindows(window).filter { $0.isVisible }
    if !children.isEmpty {
      let image = NSImage(size: view.bounds.size)
      image.lockFocusFlipped(true)
      let base = NSImage(size: view.bounds.size); base.addRepresentation(bitmap)
      base.draw(in: view.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
      let origin = window.convertToScreen(view.convert(view.bounds, to: nil))
      for child in children {
        guard let childView = child.contentView else { continue }
        childView.layoutSubtreeIfNeeded(); childView.displayIfNeeded()
        guard let representation = childView.bitmapImageRepForCachingDisplay(in: childView.bounds) else { continue }
        childView.cacheDisplay(in: childView.bounds, to: representation)
        let stamp = NSImage(size: childView.bounds.size); stamp.addRepresentation(representation)
        let frame = NSRect(x: child.frame.minX - origin.minX, y: origin.maxY - child.frame.maxY, width: child.frame.width, height: child.frame.height)
        stamp.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
      }
      image.unlockFocus()
      if let data = image.tiffRepresentation, let representation = NSBitmapImageRep(data: data) { result = representation }
    }
    guard let png = result.representation(using: .png, properties: [:]) else { throw Failure(description: "Cannot encode window content") }
    try png.write(to: url)
  }
  private static func write(_ value: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url)
  }
}
