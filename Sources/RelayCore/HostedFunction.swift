import Foundation

public struct HostedFunction: Codable, Identifiable, Sendable {
  public struct Trigger: Codable, Sendable {
    public let kind: String
    public let itemID: String?
    public let operation: String?
    public let delaySeconds: Int?
    public let expression: String?
    public let timezone: String?
    public let at: String?
  }

  public struct Run: Codable, Identifiable, Sendable {
    public let id: String
    public let revision: Int
    public let itemID: String?
    public let eventID: String?
    public let status: String
    public let scheduledAt: Date
    public let finishedAt: Date?
    public let attempts: Int
    public let writes: Int
    public let error: String?
  }

  public let id: String
  public let name: String
  public let enabled: Bool
  public let revision: Int
  public let actor: String
  public let updatedBy: String
  public let updatedAt: Date
  public let nextAt: Date?
  public let trigger: Trigger
  public let code: String?
  public let runs: [Run]?
}
