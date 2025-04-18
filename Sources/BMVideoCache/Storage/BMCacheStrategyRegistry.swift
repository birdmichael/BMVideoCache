import Foundation
public class BMCacheStrategyRegistry {
    public static let shared = BMCacheStrategyRegistry()

    public typealias ComparatorFactory = () -> ((URL, URL) -> Bool)
    
    private var factories: [String: ComparatorFactory] = [:]
    
    private init() {}
    
    
    public func register(identifier: String, factory: @escaping ComparatorFactory) {
        factories[identifier] = factory
    }
    
    public func getFactory(for identifier: String) -> ComparatorFactory? {
        return factories[identifier]
    }
    
    public func unregister(identifier: String) {
        factories.removeValue(forKey: identifier)
    }
    
    public func unregisterAll() {
        factories.removeAll()
    }
    
    public func isRegistered(identifier: String) -> Bool {
        return factories[identifier] != nil
    }
}
