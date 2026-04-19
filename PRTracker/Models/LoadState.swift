import Foundation

enum LoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case offline
    case unauthenticated(String)
    case error(String)
}

