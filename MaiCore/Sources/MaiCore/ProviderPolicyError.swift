import Foundation

/// A provider policy rejection requires user action, not a transport retry.
public struct ProviderPolicyError: LocalizedError, Equatable, Sendable {
  public let code: String
  public let message: String
  public let statusCode: Int?
  public let requestID: String?
  public let parameter: String?

  public init(
    code: String, message: String, statusCode: Int? = nil, requestID: String? = nil,
    parameter: String? = nil
  ) {
    self.code = code
    self.message = message
    self.statusCode = statusCode
    self.requestID = requestID
    self.parameter = parameter
  }

  public var errorDescription: String? {
    var details: [String] = []
    if let statusCode { details.append("HTTP \(statusCode)") }
    details.append("code: \(code)")
    if let parameter { details.append("parameter: \(parameter)") }
    if let requestID { details.append("request: \(requestID)") }
    return message + " (" + details.joined(separator: "; ") + ")"
  }
}
