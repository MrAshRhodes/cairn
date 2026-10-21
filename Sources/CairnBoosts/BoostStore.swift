import Foundation
import Observation
import CairnCore
import CairnEngineKit

@MainActor @Observable
public final class BoostStore {
    public private(set) var boosts: [Boost] = []
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public func load() throws { throw ServiceError.notImplemented }
    public func save() throws { throw ServiceError.notImplemented }
    public func add(_ boost: Boost) throws { throw ServiceError.notImplemented }
    public func update(_ boost: Boost) throws { throw ServiceError.notImplemented }
    public func remove(_ id: UUID) throws { throw ServiceError.notImplemented }
    public func scripts(for url: URL?) -> [EngineUserScript] { [] }
}
