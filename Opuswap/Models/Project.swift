import Foundation
import SwiftData

@Model
class Project {
    @Attribute(.unique) var path: String  // "-Users-toro-myapp-Mugendesk"
    var displayName: String               // "Mugendesk"
    @Relationship(deleteRule: .cascade, inverse: \Session.project)
    var sessions: [Session] = []
    var createdAt: Date
    var updatedAt: Date

    init(path: String, displayName: String, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.path = path
        self.displayName = displayName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
