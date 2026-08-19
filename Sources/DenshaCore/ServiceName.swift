public enum ServiceName {
    public static let separator: Character = "/"

    public static func qualified(project: String?, name: String) -> String {
        guard let project, !project.isEmpty else { return name }
        return "\(project)\(separator)\(name)"
    }

    public static func project(of qualified: String) -> String? {
        guard let slash = qualified.firstIndex(of: separator) else { return nil }
        return String(qualified[qualified.startIndex..<slash])
    }

    public static func short(of qualified: String) -> String {
        guard let slash = qualified.firstIndex(of: separator) else { return qualified }
        return String(qualified[qualified.index(after: slash)...])
    }
}

extension ServiceStatus {
    public var project: String? { ServiceName.project(of: name) }
    public var shortName: String { ServiceName.short(of: name) }
}

extension ResolvedService {
    public var project: String? { ServiceName.project(of: name) }
    public var shortName: String { ServiceName.short(of: name) }
}
