import Foundation

@main
enum ColumnChecks {
  static func main() throws {
    var count = 0
    func check(_ value: Bool, _ title: String) throws {
      guard value else { throw NSError(domain: "ColumnChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: title]) }; count += 1
    }
    let original = DetailColumns()
    try check(original.automatic && original.visible.count == 5, "Legacy preferences retain responsive defaults")
    try check(DetailColumns(propertyList: nil) == nil, "Missing columns inherit without migration writes")
    try check(DetailColumns(propertyList: ["version": 2]) == nil, "Unknown schema inherits safely")
    try check(DetailColumns(propertyList: "invalid") == nil, "Invalid group inherits safely")
    var custom = original; custom.automatic = false; custom.order = ["name", "size", "created", "modified", "kind"]; custom.visible.remove("kind"); custom.widths["created"] = 214
    try check(DetailColumns(propertyList: custom.propertyList) == custom, "User order, visibility and widths round-trip independently")
    let data = try PropertyListSerialization.data(fromPropertyList: custom.propertyList, format: .binary, options: 0)
    try check(DetailColumns(propertyList: PropertyListSerialization.propertyList(from: data, format: nil)) == custom, "Binary preferences round-trip")
    let repaired = DetailColumns(propertyList: ["version": 1, "order": ["size", "size", "future", "name"], "visible": ["future", "size"], "widths": ["name": -1, "size": 0, "created": Double.infinity, "modified": true, "kind": "132"]])!
    try check(repaired.order == ["size", "name", "modified", "created", "kind"], "Duplicates and unknown columns cannot replace required identifiers")
    try check(repaired.visible == ["name", "size"], "Name cannot be hidden and unknown identifiers are ignored")
    try check(repaired.widths == original.widths, "Negative, zero, infinite, boolean and string widths use defaults")
    try check(DetailColumns(propertyList: ["version": 1, "visible": []])!.visible == ["name"], "An empty visibility list still shows Name")
    try check(DetailColumns(propertyList: ["version": 1, "widths": ["name": 150, "size": 2000]])!.widths["size"] == 2000, "Valid width bounds survive")
    try check(DetailColumns(propertyList: ["version": 1, "widths": ["name": 149, "size": 2001, "created": Double.nan]])!.widths == original.widths, "Out-of-range and NaN widths cannot overflow the table")
    try check(DetailColumns(propertyList: ["version": 1, "order": 17, "visible": 17, "widths": 17])!.order == original.order, "Malformed members retain known defaults")
    let suite = "native-column-checks." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["view": "details", "sort": "created", "ascending": false, "columns": custom.propertyList], forKey: "defaultFolderView")
    let saved = defaults.dictionary(forKey: "defaultFolderView")!
    try check(DetailColumns(propertyList: saved["columns"]) == custom && saved["sort"] as? String == "created", "Column group coexists with sort/layout in temporary preferences")
    print("Detail column checks passed: \(count); no user files or preferences used.")
  }
}
