import Foundation

enum FileSelectionNode: Hashable {
  case root
  case group(String)
  case item(String, group: String?, identity: Data? = nil)

  var path: String? {
    guard case let .item(path, _, _) = self else { return nil }
    return path
  }

  var groupID: String? {
    switch self {
    case .root: return nil
    case let .group(id), let .item(_, id?, _): return id
    case .item(_, nil, _): return nil
    }
  }

  var identity: Data? {
    guard case let .item(_, _, identity) = self else { return nil }
    return identity
  }
}

struct FileSelectionTopology {
  let rows: [FileSelectionNode]
  let rowByNode: [FileSelectionNode: Int]
  let nodesByPath: [String: [FileSelectionNode]]
  let items: [FileSelectionNode]
  let hiddenItems: [FileSelectionNode]
  let fileRows: IndexSet
  private let hiddenGroups: Set<String>
  private let groupRows: [String: Range<Int>]
  private let uniquePathsByIdentity: [Data: String]

  init(rows: [FileSelectionNode] = [], items: [FileSelectionNode]? = nil, hiddenGroups: Set<String> = []) {
    self.rows = rows
    self.hiddenGroups = hiddenGroups
    self.items = items ?? rows
    hiddenItems = hiddenGroups.isEmpty ? [] : self.items.filter { node in
      node.groupID.map(hiddenGroups.contains) ?? false
    }
    rowByNode = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1, $0) })
    var paths: [String: [FileSelectionNode]] = [:]
    var uniquePaths: [Data: String] = [:], ambiguous = Set<Data>()
    for node in self.items {
      guard let path = node.path else { continue }
      paths[path, default: []].append(node)
      guard let identity = node.identity, !ambiguous.contains(identity) else { continue }
      if let existing = uniquePaths[identity], existing != path {
        uniquePaths.removeValue(forKey: identity)
        ambiguous.insert(identity)
      } else {
        uniquePaths[identity] = path
      }
    }
    nodesByPath = paths
    uniquePathsByIdentity = uniquePaths
    var groups: [String: Range<Int>] = [:]
    var files = IndexSet()
    for (row, node) in rows.enumerated() {
      guard case let .item(_, group, _) = node else { continue }
      files.insert(row)
      if let group { groups[group] = (groups[group]?.lowerBound ?? row)..<(row + 1) }
    }
    groupRows = groups
    fileRows = files
  }

  func rows(inGroup id: String) -> Range<Int>? { groupRows[id] }

  func matchingItems(_ node: FileSelectionNode, previous: FileSelectionTopology?) -> [FileSelectionNode] {
    guard let path = node.path else { return [] }
    if let nodes = nodesByPath[path],
       node.identity == nil || nodes.first?.identity == nil || node.identity == nodes.first?.identity {
      return nodes
    }
    guard let identity = node.identity, previous?.uniquePathsByIdentity[identity] == path,
          let renamed = uniquePathsByIdentity[identity] else { return [] }
    return nodesByPath[renamed] ?? []
  }

  func visibleNode(_ node: FileSelectionNode?, previous: FileSelectionTopology? = nil) -> FileSelectionNode? {
    guard let node else { return nil }
    if rowByNode[node] != nil { return node }
    let visible = matchingItems(node, previous: previous).filter { rowByNode[$0] != nil }
    return visible.first { $0.groupID == node.groupID } ?? (visible.count == 1 ? visible.first : nil)
  }

  func range(from first: FileSelectionNode, to last: FileSelectionNode) -> [FileSelectionNode] {
    guard let firstRow = rowByNode[first], let lastRow = rowByNode[last] else { return [last] }
    let lower = min(firstRow, lastRow), upper = max(firstRow, lastRow)
    var result: [FileSelectionNode] = []
    var row = lower
    while row <= upper {
      let node = rows[row]
      if case let .item(_, id?, _) = node, let group = groupRows[id],
         group.lowerBound == row, row > lower, group.upperBound <= upper {
        result.append(.group(id))
        row = group.upperBound
      } else {
        if node.path != nil || node.groupID.map(hiddenGroups.contains) == true { result.append(node) }
        row += 1
      }
    }
    return result
  }
}

struct FileSelectionModifiers: OptionSet {
  let rawValue: Int
  static let shift = Self(rawValue: 1)
  static let toggle = Self(rawValue: 2)
}

enum FileSelectionAction {
  case click(FileSelectionNode, FileSelectionModifiers)
  case move(FileSelectionNode, FileSelectionModifiers)
  case set(FileSelectionNode, Bool)
  case changeItems(added: [FileSelectionNode], removed: [FileSelectionNode], focus: FileSelectionNode?)
  case all
  case clear
  case clearItems
  case marquee(entered: [FileSelectionNode], exited: [FileSelectionNode], toggle: Bool)
}

struct SelectionState: Equatable {
  private enum RangeAnchor: Equatable {
    case item(FileSelectionNode)
    case removed(FileSelectionNode)

    var node: FileSelectionNode {
      switch self { case let .item(node), let .removed(node): return node }
    }
  }

  private var itemStates: [FileSelectionNode: Bool] = [:]
  private var groupStates: [FileSelectionNode: Bool] = [:]
  var marks: [FileSelectionNode: Bool] { groupStates.merging(itemStates) { _, item in item } }
  private var rangeAnchor: RangeAnchor?
  var anchor: FileSelectionNode? { rangeAnchor?.node }
  private(set) var focus: FileSelectionNode?

  func contains(_ node: FileSelectionNode) -> Bool {
    switch node {
    case let .item(_, id, _):
      if let mark = itemStates[node] { return mark }
      if let id, let mark = groupStates[.group(id)] { return mark }
    case .group, .root:
      if let mark = groupStates[node] { return mark }
    }
    return groupStates[.root] ?? false
  }

  func visibleRows(in topology: FileSelectionTopology) -> IndexSet {
    var rows = groupStates[.root] == true ? topology.fileRows : IndexSet()
    for (node, selected) in groupStates {
      guard case let .group(id) = node, let range = topology.rows(inGroup: id) else { continue }
      if selected { rows.insert(integersIn: range) } else { rows.remove(integersIn: range) }
    }
    for (node, selected) in itemStates {
      guard let row = topology.rowByNode[node] else { continue }
      if selected { rows.insert(row) } else { rows.remove(row) }
    }
    return rows
  }

  mutating func set(_ node: FileSelectionNode, selected: Bool) {
    switch node {
    case .root:
      clearItems()
      if selected { groupStates[node] = true }
    case let .group(id):
      groupStates.removeValue(forKey: node)
      itemStates = itemStates.filter { $0.key.groupID != id }
      if contains(node) != selected { groupStates[node] = selected }
    case .item:
      itemStates.removeValue(forKey: node)
      if contains(node) != selected { itemStates[node] = selected }
    }
  }

  mutating func replace(paths: Set<String>, topology: FileSelectionTopology) {
    self = Self()
    for path in paths {
      for node in topology.nodesByPath[path] ?? [] { itemStates[node] = true }
    }
    focus = itemStates.keys.max { (topology.rowByNode[$0] ?? -1) < (topology.rowByNode[$1] ?? -1) }
    rangeAnchor = focus.map(RangeAnchor.item)
  }

  mutating func reconcile(with topology: FileSelectionTopology, previous: FileSelectionTopology? = nil) {
    groupStates = groupStates.filter { $0.key == .root || topology.rowByNode[$0.key] != nil }
    var result: [FileSelectionNode: Bool] = [:]
    for (node, mark) in itemStates {
      let nodes = topology.matchingItems(node, previous: previous)
      if nodes.contains(node) { result[node] = mark }
      else if let matchingGroup = nodes.first(where: { $0.groupID == node.groupID }) { result[matchingGroup] = mark }
      else if nodes.count == 1 { result[nodes[0]] = mark }
    }
    itemStates = result
    if let previous {
      // Inherited selection must not include new or replaced files after a refresh.
      for node in topology.items where node.path != nil && itemStates[node] == nil && contains(node) {
        if previous.matchingItems(node, previous: topology).isEmpty { set(node, selected: false) }
      }
    }
    if case let .item(anchor) = rangeAnchor {
      if let visible = topology.visibleNode(anchor, previous: previous) { rangeAnchor = .item(visible) }
      else if topology.matchingItems(anchor, previous: previous).isEmpty { rangeAnchor = .removed(anchor) }
    }
    if let visible = topology.visibleNode(focus, previous: previous) {
      focus = visible
    } else if let focus, let previous, let index = previous.rowByNode[focus], topology.matchingItems(focus, previous: previous).isEmpty {
      let after = previous.rows.suffix(from: index + 1).lazy.compactMap { topology.visibleNode($0) }.first { $0.path != nil }
      self.focus = after ?? previous.rows.prefix(index).reversed().lazy.compactMap { topology.visibleNode($0) }.first { $0.path != nil }
    } else {
      focus = nil
    }
  }

  mutating func regroup(from old: FileSelectionTopology, to new: FileSelectionTopology) {
    let previouslySelected = Set(old.items.lazy.filter(contains).compactMap(\.path))
    let all = groupStates[.root] == true
    itemStates.removeAll()
    groupStates = all ? [.root: true] : [:]
    for node in new.rows {
      guard let path = node.path else { continue }
      let selected = previouslySelected.contains(path)
      if selected != all { itemStates[node] = selected }
    }
  }

  mutating func apply(_ action: FileSelectionAction, topology: FileSelectionTopology) {
    switch action {
    case let .click(node, flags):
      if flags.contains(.shift) { extend(to: node, toggle: flags.contains(.toggle), topology: topology) }
      else if flags.contains(.toggle) {
        set(node, selected: !contains(node))
        focus = node
        rangeAnchor = .item(node)
      } else { selectOnly(node) }
    case let .move(node, flags):
      if flags.contains(.shift) { extend(to: node, toggle: flags.contains(.toggle), topology: topology) }
      else if flags.contains(.toggle) { focus = node }
      else { selectOnly(node) }
    case let .set(node, selected):
      set(node, selected: selected)
      focus = node
      rangeAnchor = .item(node)
    case let .changeItems(added, removed, newFocus):
      for node in removed { set(node, selected: false) }
      for node in added { set(node, selected: true) }
      if let newFocus { focus = newFocus; rangeAnchor = .item(newFocus) }
    case .all:
      set(.root, selected: true)
    case .clear:
      self = Self()
    case .clearItems:
      clearItems()
    case let .marquee(entered, exited, toggle):
      for node in exited { set(node, selected: toggle && !contains(node)) }
      for node in entered { set(node, selected: !toggle || !contains(node)) }
    }
  }

  private mutating func clearItems() {
    itemStates.removeAll()
    groupStates.removeAll()
  }

  private mutating func selectOnly(_ node: FileSelectionNode) {
    clearItems()
    set(node, selected: true)
    focus = node
    rangeAnchor = .item(node)
  }

  private mutating func extend(to node: FileSelectionNode, toggle: Bool, topology: FileSelectionTopology) {
    if case .removed = rangeAnchor {
      if !toggle { clearItems() }
      focus = node
      return
    }
    let start = topology.visibleNode(anchor) ?? topology.visibleNode(focus) ?? node
    let selected = !toggle || contains(start)
    if !toggle { clearItems() }
    for item in topology.range(from: start, to: node) { set(item, selected: selected) }
    rangeAnchor = .item(start)
    focus = node
  }
}
