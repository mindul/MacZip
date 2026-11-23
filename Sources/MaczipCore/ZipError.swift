import Foundation

public enum ZipError: Error, Equatable {
    case notAZip
    case corrupt(String)
    case unsupportedMethod(UInt16)
    case unsupportedAES(entry: String)
    case passwordRequired
    case wrongPassword
    case crcMismatch(entry: String)
    case unsafePath(String)
    case tooLarge(String)
    case cancelled
    case io(String)
}
