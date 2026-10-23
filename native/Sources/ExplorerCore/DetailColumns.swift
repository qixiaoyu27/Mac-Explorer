import Foundation
import CoreFoundation

/// User intent only. Responsive hiding and fitted widths must never be persisted here.
public struct DetailColumns: Equatable, Sendable {
  public static let identifiers = ["name", "modified", "created", "kind", "size"]
  public static let defaultWidths: [String: Double] = ["name": 450, "modified": 165, "created": 165, "kind": 132, "size": 100]
  public var order = identifiers
  public var visible = Set(identifiers)
  public var widths = defaultWidths
  public var automatic = true
  public init() {}
  public init?(propertyList: Any?) {
    guard let data = propertyList as? [String: Any], data["version"] as? Int == 1 else { return nil }
    self.init()
    var seen = Set<String>()
    order = ((data["order"] as? [String] ?? []) + Self.identifiers).filter { Self.identifiers.contains($0) && seen.insert($0).inserted }
    if let values = data["visible"] as? [String] { visible = Set(values).intersection(Self.identifiers); visible.insert("name") }
    if let values = data["widths"] as? [String: Any] {
      for id in Self.identifiers {
        if let number = values[id] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
          (Self.minimumWidth(id)...2000).contains(number.doubleValue) { widths[id] = number.doubleValue }
      }
    }
    automatic = data["automatic"] as? Bool ?? false
  }
  public static func minimumWidth(_ id: String) -> Double { id == "name" ? 150 : id == "size" ? 64 : id == "kind" ? 80 : 120 }
  public var propertyList: [String: Any] {
    ["version": 1, "order": order, "visible": order.filter { visible.contains($0) }, "widths": widths, "automatic": automatic]
  }
}
