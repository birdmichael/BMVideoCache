import Foundation
internal protocol BMDataLoaderManaging: AnyObject {
    func isLoaderActive(forKey key: String) -> Bool
    func startPreload(forKey key: String, length: Int64) async -> Result<Void, Error>
}
