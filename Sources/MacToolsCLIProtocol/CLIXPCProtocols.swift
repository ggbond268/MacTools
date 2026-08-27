import Foundation

@objc public protocol CLIBrokerXPCProtocol {
    func handshake(_ request: Data, withReply reply: @escaping (Data) -> Void)
    func registerHost(_ registration: Data, withReply reply: @escaping (Data) -> Void)
    func send(_ request: Data, withReply reply: @escaping (Data) -> Void)
    func cancel(_ requestID: UUID, withReply reply: @escaping (Bool) -> Void)
}

@objc public protocol CLIHostXPCProtocol {
    func handle(_ request: Data, withReply reply: @escaping (Data) -> Void)
    func cancel(_ requestID: UUID, withReply reply: @escaping (Bool) -> Void)
}
