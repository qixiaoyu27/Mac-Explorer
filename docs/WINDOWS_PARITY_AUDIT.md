# Windows 资源管理器行为对齐审计

日期：2026-10-23。范围：原生 Swift/AppKit 版；基于 PR #30 的 `ce65b61` 加本轮导航修复。导航修复已提交为 `71569a6`，与后续文件工作流补齐一并整理到 PR #30（`codex/finder-servers-fresh-launch`），未安装。下表已按后续文件工作流补齐更新；实现边界及属性写入计划见 [文件工作流整理](FILE_WORKFLOW_PARITY.md)。

这是一份代码和隔离夹具审计，不是 Windows/Mac 双机逐项验收。下面的「已确认」指源码可直接证明当前实现/缺口；涉及 Windows 版本差异、外设和系统扩展的行为单独列为待实机比较。列表限定于文件管理工作流，不把 Windows 专属系统组件全部算作应用缺陷。

## 本轮导航修复

- 普通文件系统目录的每个标签页按访问历史保存选择、滚动位置及可见条目锚点；最多保留 128 个访问位置，运行时状态不写入全局文件夹偏好或退出会话。
- 返回、前进、向上和祖先面包屑使用相同恢复路径；返回父目录时选中来自路径中的直接子文件夹，并在必要时将其滚动到可见区域。
- 新位置从开头显示；同一目录的不同标签页互不串状态；显式刷新保留当前状态；取消的异步加载不能覆盖新位置。
- 包括详细信息、四种图标大小、列表、平铺、内容；列表单独覆盖水平滚动，并修复 AppKit 重布局时将水平文档宽度压回视口的问题。
- 夹具覆盖快速返回、删除子目录、历史分支裁剪等异常路径。实际结果见 `native/output/validation/smoke/report.json`；不把「已有测试入口」当成通过结果。

## 导航提交的验证结果

- 最终隔离原生构建及严格代码签名检查通过；562 条源文案的英文、繁中目录检查通过。
- 独立导航专项 62 项通过；完整 AppKit 报告 `passed: true`，554 条结果，原始夹具 `fixturePreserved: true`。其中 SVN UI 因缺少 `svn` / `svnadmin` 跳过，不冒充 SVN 实机通过。
- 文件操作全部限制在临时夹具；没有对真实 NAS 文件做修改，也没有覆盖 Applications 日常版。
- 初次检查暴露目录 URL 尾斜杠比较和水平列表文档宽度问题，已修复并回归。完整回归还暴露既有 VCS 编辑器夹具在前置子进程检查后未激活应用的问题；已显式激活测试应用，保留原焦点断言，最终整套通过。

## 已补齐的文件工作流

网络永久删除确认及服务器权限错误分类、五列定制和持久化、文件重做、属性名称编辑及详情/权限只读页已在本分支实现。新增能力不代表全部 Windows 行为已对齐，也不代表真实 NAS 验收已完成；最新验证结果见 [本轮记录](FILE_WORKFLOW_PARITY.md#验证记录)。

## 已确认的行为差异和功能缺口

优先级：P1 为高频交互，P2 为工作流能力，P3 为增强；这里只列出后续候选，不自动授权本轮全部实现。

| 优先级 | 项目 | 当前实现与影响 | 源码证据 / 后续建议 |
| --- | --- | --- | --- |
| P1 | Enter 默认动作 | Enter 绑定重命名；打开用 Command+O / Command+Down。与 Windows 内容区 Enter 打开不同。 | `ExplorerShortcuts.swift` 的 `rename/open`、`Views.swift` 的 `keyDown`。建议提供明确的 Windows/macOS 键位方案，保留已有自定义绑定。 |
| P1 | Backspace 的「后退」与「上一级」 | Backspace 当前绑定上一级。如果先从别处跳到当前目录，结果会和历史后退不同。 | `ExplorerShortcuts.swift` 的 `parent/back`；需独立于本次视口恢复处理。 |
| P1 | Alt+Enter | 当前绑定详细信息窗格，不是独立属性对话框；后者已有右键入口。 | `ExplorerShortcuts.swift` 的 `details-pane`、`BrowserController.showProperties`。 |
| P1 | 图标网格的键盘选择 | 集合视图 Up/Down 按线性索引 ±1，并非按视觉上一行移动；Shift 方向键用集合追加，反向收缩与稳定锚点尚未完整实现。 | `Views.swift` 的 `FileCollectionView.keyDown`；应覆盖多列、小图标、平铺、列表的不同空间方向，另做选择模型回归。 |
| P1 | 搜索结果的历史恢复 | 导航历史只有目录 URL；切换历史/标签会清空查询，运行中的搜索及结果位置不能按原搜索页恢复。本轮普通目录位置缓存有意排除搜索页。 | `BrowserController.travelHistory/switchTab/performSearch`、`BrowserTab.history`。应将目录页与搜索页建模为不同的导航项。 |
| P2 | 更多详细信息元数据列 | 现有五列已支持显隐、顺序、宽度及持久化；尚无媒体/文档等更多元数据列。 | `DetailColumns`、`BrowserController.columnMenu`。后续按文件类型后台读取，避免网络目录逐文件阻塞。 |
| P2 | 分组与多关键字排序 | 只有单个排序键和方向，没有按类型/日期等分组、组折叠，或组合排序。 | `BrowserController.sortMenu/recompute`、`EntryQuery.apply`。不能把已有创建日期排序当成完整分组功能。 |
| P2 | 高级搜索/内容搜索 | 只匹配名称，支持普通文本、通配符、正则；无 AQS 属性查询、文件内容查询或索引搜索。单次上限为访问 30,000 项或匹配 1,000 项，截断会报告。 | `ExplorerCore/FileSearch.swift`。日期/大小/类型过滤可先做，不要求照搬 Windows Search 服务。 |
| P2 | 批量重命名 | 重命名入口要求只选一项，没有多项编号重命名或批处理预览。 | `BrowserController.renameSelected` 和菜单 `chosen.count == 1`。建议加入碰撞预检和可撤销的批处理。 |
| P2 | 更多属性写入与扩展 | 常规名称已可编辑，新增详情和权限只读页；隐藏、只读、权限、扩展属性和媒体字段仍不能写入。 | `ExplorerDialogs.EDPropertiesBody`、`FilePropertiesReader`；详细的映射、身份、读回及撤销方案见 [文件工作流整理](FILE_WORKFLOW_PARITY.md)。 |
| P2 | 恢复会话的完整度 | 已有退出恢复开关，但重启只保存窗口框和标签 URL；不保存活动标签、每标签前进后退历史、选择和视口。恢复时还有个人文件夹锚点。 | `NativeSavedWindow`、`ApplicationDelegate.restoreWindows`、`BrowserController.restoreLocations`。本轮运行时位置缓存没有扩展为磁盘会话格式。 |
| P3 | 重新打开已关闭标签 | 没有关闭标签历史和恢复入口。 | `BrowserController.closeTab` 直接移除，`ExplorerShortcuts.actions` 无恢复动作。应区分关闭标签和退出会话。 |

键位参照微软的[Windows 快捷键](https://support.microsoft.com/en-us/accessibility/windows/keyboard-shortcuts-in-windows)和[资源管理器内容区导航说明](https://support.microsoft.com/en-us/accessibility/windows/use-a-screen-reader-to-explore-and-navigate-file-explorer-in-windows)。搜索能力参照 [Windows Search AQS](https://learn.microsoft.com/en-us/windows/win32/search/-search-3x-advancedquerysyntax)；分组是 Shell 文件夹视图的独立能力，参见 [IFolderView2::GetGroupBy](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-ifolderview2-getgroupby)。这些文档不能证明当前 Windows 每一版本的像素布局和全部边界行为。

## 已确认的能力边界，需先确定产品策略

| 项目 | 当前边界 | 为什么不直接当作普通缺陷修掉 |
| --- | --- | --- |
| 碰撞替换和目录合并 | 冲突提供重试、保留两者、跳过、取消；没有覆盖替换或递归合并。 | 现有仓库明确要求不覆盖用户文件。若扩展，必须定义可恢复替换、合并取消及撤销语义。证据：`NativeTransferPanel.requestDecision`、`VerifiedTransfer`。 |
| 传输暂停、恢复及剩余时间 | 已显示速度、字节和处理阶段，具备取消；没有暂停按钮、持久断点续传或剩余时间估计。 | 暂停和断线后续传是不同承诺。Windows 具体支持范围也要实机核对，不能把协议重试当成完整续传。证据：`NativeTransferPanel`、`FileTransferControl`。 |
| SMB 元数据与服务端复制 | 主数据服务端复制已实现；创建日期、扩展属性、ACL 等取决于卷/服务器支持，可能要求明确接受属性损失。 | 保留已有安全检查，不为「对齐」静默忽略属性差异；不能承诺任意 NAS 都能全属性无损。详见 `NAS_ATTRIBUTE_ACCEPTANCE.md` 和 `SERVER_SIDE_TRANSFER.md`。 |
| macOS 系统接入 | 使用实际挂载点、系统回收站、钥匙串、Quick Look、系统共享与权限弹窗；没有 Windows 盘符、Shell 扩展、NTFS 权限页或 OneDrive 的等价系统服务。 | 属于平台差异；需逐项明确替代方案，不能一律列为待复制的 Windows 功能。 |

## 仍需 Windows/Mac 双机或真实外设复核

1. F6/Shift+F6、Tab 和导航树的焦点顺序；导航树已有 Enter/Space 和左右展开收起，不能说成「完全没有键盘导航」，但整套树遍历和数字键盘展开组合仍需对照。
2. 图标/平铺/内容视图的字符定位、PageUp/PageDown、Home/End、左右键和多选锚点的完整组合。
3. 跨排序/隐藏项目/窗口宽度/预览窗格变化时，Windows 的具体视口锚点策略；本轮先保证已进入文件夹可见并限制滚动范围。
4. 多窗口复制与移动、长时间传输、多批次传输对话框的交互，以及取消时的实际残留报告。
5. Windows 11 当前版本的右键菜单层级、列菜单、触屏、屏幕阅读器与缩放行为；自定义 AppKit 控件需要另做辅助功能验收。
6. 真实 Finder 剪贴板、iCloud 同步/占位文件、AirDrop 接收方、不同 SMB 服务器、断网/空间不足/macOS 13 实机；已有隔离检查不能替代这些环境。

## 建议的后续批次

1. P1 键位与空间选择；先决定是否提供独立 Windows 键位方案。
2. 搜索页/历史建模与完整会话恢复。
3. 更多元数据列、分组、组合排序。
4. 批量重命名。
5. 更多属性写入、碰撞替换/目录合并、暂停恢复等需要安全语义设计的工作。

以上为候选顺序，不表示本轮已经开始实现。
