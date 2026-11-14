/// Rebuilt only when exclusions change; hot-path lookups allocate no new set.
struct ExclusionIndex {
    private var identifiers: Set<String>
    private(set) var rebuildCount = 1

    init(_ values: [String]) { identifiers = Set(values.map { $0.lowercased() }) }

    mutating func replace(with values: [String]) {
        identifiers = Set(values.map { $0.lowercased() })
        rebuildCount += 1
    }

    func contains(bundleIdentifier: String?, localizedName: String?) -> Bool {
        if let bundleIdentifier, identifiers.contains(bundleIdentifier.lowercased()) { return true }
        if let localizedName, identifiers.contains(localizedName.lowercased()) { return true }
        return false
    }
}
