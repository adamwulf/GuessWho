import Foundation

public enum ContactStoreError: Error, Sendable {
    case contactNotFound(localID: String)
}
