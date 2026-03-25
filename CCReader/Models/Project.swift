import Foundation
import SwiftData

@Model
public class Project {
    @Attribute(.unique) public var path: String
    public var displayName: String
    @Relationship(deleteRule: .cascade, inverse: \Session.project)
    public var sessions: [Session] = []
    public var createdAt: Date
    public var updatedAt: Date

    public init(path: String, displayName: String, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.path = path
        self.displayName = displayName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
