import Foundation
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Where the current plan stands: the remaining share of each limit and when
/// it resets. Ollama Cloud is the only provider that publishes one today, at
/// `GET /api/balance`, and it answers in one of two shapes: included credits
/// in dollars (`balance_usd` / `allowance_usd`) on a monthly plan, or the
/// session and weekly percentages of a legacy one.
public struct MaiProviderStatus: Codable, Equatable, Sendable {
  public struct Limit: Codable, Equatable, Sendable {
    /// Share of the limit that is still usable, 0…100.
    public var remainingPercent: Double
    public var resetsAt: Date?
    /// The reset as the provider or agent phrased it, for a source that gives
    /// a local time in words rather than a timestamp.
    public var resetsText: String?

    public init(remainingPercent: Double, resetsAt: Date? = nil, resetsText: String? = nil) {
      self.remainingPercent = remainingPercent
      self.resetsAt = resetsAt
      self.resetsText = resetsText
    }
  }

  public enum Balance: Codable, Equatable, Sendable {
    case credits(remaining: Double, allowance: Double, resetsAt: Date?)
    /// Money bought on top of the plan.
    case purchased(Double)

    /// In a short line, an empty credit balance only adds noise.
    var isWorthShowing: Bool {
      switch self {
      case .credits(let remaining, _, _), .purchased(let remaining): return remaining > 0
      }
    }

    /// The wire form, kept flat so a host can build it without a schema.
    var payload: [String: Any] {
      switch self {
      case .credits(let remaining, let allowance, let resetsAt):
        return [
          "kind": "credits", "remainingUSD": remaining, "allowanceUSD": allowance,
          "resetsAt": resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
        ]
      case .purchased(let amount):
        return ["kind": "purchased", "balanceUSD": amount]
      }
    }

    /// Reads either the dictionary form above or the `JSONValue` form a host
    /// received, whose numbers may be integers.
    init?(payload: [String: Any]) {
      func number(_ key: String) -> Double? {
        if let value = payload[key] as? Double { return value }
        if let value = payload[key] as? Int { return Double(value) }
        return nil
      }
      switch payload["kind"] as? String {
      case "credits":
        guard let remaining = number("remainingUSD") else { return nil }
        self = .credits(
          remaining: remaining, allowance: number("allowanceUSD") ?? remaining,
          resetsAt: MaiProviderStatus.date(payload["resetsAt"]))
      case "purchased":
        guard let amount = number("balanceUSD") else { return nil }
        self = .purchased(amount)
      default:
        return nil
      }
    }
  }

  public var provider: String
  public var plan: String?
  /// Rolling limits, shortest first.
  public var limits: [String: Limit]
  public var balances: [Balance]
  /// Requests the account made in the last seven days and today, from
  /// `GET /api/usage`. A credits plan reports no tokens or money there.
  public var requestsLast7Days: Int?
  public var requestsToday: Int?
  /// What an agent said in its own words when its answer had no numbers this
  /// version could read. Shown instead of claiming there is no data.
  public var note: String?

  public init(
    provider: String, plan: String? = nil, limits: [String: Limit] = [:],
    balances: [Balance] = [], requestsLast7Days: Int? = nil, requestsToday: Int? = nil,
    note: String? = nil
  ) {
    self.provider = provider
    self.plan = plan
    self.limits = limits
    self.balances = balances
    self.requestsLast7Days = requestsLast7Days
    self.requestsToday = requestsToday
    self.note = note
  }

  /// Reads the `_pmai/status` answer of an ACP host. An unsupported or
  /// malformed answer is nil rather than an error: a client shows nothing
  /// rather than failing the turn.
  public init?(payload: JSONValue) {
    guard let object = payload.objectValue, object["supported"]?.boolValue == true,
      let provider = object["provider"]?.stringValue, !provider.isEmpty,
      object["error"] == nil
    else { return nil }
    var limits: [String: Limit] = [:]
    for (name, value) in object["limits"]?.objectValue ?? [:] {
      let fields = value.objectValue ?? [:]
      guard let remaining = fields["remainingPercent"]?.coercedNumberValue else { continue }
      limits[name] = Limit(
        remainingPercent: remaining, resetsAt: Self.date(fields["resetsAt"]?.stringValue),
        resetsText: fields["resetsText"]?.stringValue)
    }
    // A `JSONValue` keeps an integer apart from a double; flatten it back to
    // `Any` with the number's own value so `Balance` reads both.
    let balances = (object["balances"]?.arrayValue ?? []).compactMap { item -> Balance? in
      var fields: [String: Any] = [:]
      for (key, value) in item.objectValue ?? [:] {
        switch value {
        case .number(let number): fields[key] = number
        case .integer(let number): fields[key] = number
        case .string(let text): fields[key] = text
        default: fields[key] = value
        }
      }
      return Balance(payload: fields)
    }
    self.init(
      provider: provider, plan: object["plan"]?.stringValue, limits: limits, balances: balances)
    requestsLast7Days = object["requestsLast7Days"]?.intValue
    requestsToday = object["requestsToday"]?.intValue
    note = object["note"]?.stringValue
  }

  /// The `_pmai/status` answer, which the ACP client decodes back.
  public var payload: [String: Any] {
    [
      "supported": true, "provider": provider, "plan": plan ?? "", "summary": summary(),
      "requestsLast7Days": requestsLast7Days ?? 0, "requestsToday": requestsToday ?? 0,
      "note": note ?? "",
      "limits": limits.mapValues { limit in
        [
          "remainingPercent": limit.remainingPercent,
          "resetsAt": limit.resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
          "resetsText": limit.resetsText ?? "",
        ] as [String: Any]
      },
      "balances": balances.map(\.payload),
    ]
  }

  /// `ollamacloud · pro · session 33% (3h 07m) · weekly 70% (6d 9h)`.
  /// How much is left and when it resets. `compact` keeps the line to the one
  /// limit that resets soonest, for a status bar or a `/status` line.
  public func summary(
    now: Date = Date(), providerLabel: String? = nil, compact: Bool = false
  ) -> String {
    let requestLast7 = (requestsLast7Days ?? 0).formatted(.number.grouping(.never))
    let requestToday = (requestsToday ?? 0).formatted(.number.grouping(.never))
    var parts = [providerLabel ?? provider]
    if let plan, !plan.isEmpty { parts.append(plan) }
    // The window that bites first is read first: a session, then the week it
    // sits in, then the per-model shares of it.
    for name in limits.keys.sorted(by: Self.orderOfLimits(limits)).prefix(compact ? 1 : .max) {
      guard let limit = limits[name] else { continue }
      var text = "\(name) \(Int(limit.remainingPercent.rounded()))%"
      if let resetsAt = limit.resetsAt, resetsAt > now {
        text += " (\(Self.countdown(resetsAt.timeIntervalSince(now))))"
      } else if let resetsText = limit.resetsText, !resetsText.isEmpty {
        text += " (\(resetsText))"
      }
      parts.append(text)
    }
    for balance in balances where !compact || balance.isWorthShowing {
      switch balance {
      case .credits(let remaining, let allowance, let resetsAt):
        var text = Self.money(remaining) + " of " + Self.money(allowance)
        if let resetsAt, resetsAt > now {
          text += " left (\(Self.countdown(resetsAt.timeIntervalSince(now))))"
        } else {
          text += " left"
        }
        parts.append(text)
      case .purchased(let amount):
        parts.append(Self.money(amount) + " credit")
      }
    }
    if !compact, let requestsLast7Days, requestsLast7Days > 0 {
      parts.append("\(requestLast7) req · \(requestToday) today")
    }
    // Only the provider's own words are left to show.
    if parts.count == 1, let note, !note.isEmpty { return note }
    return parts.joined(separator: " · ")
  }

  /// Session before week before per-model week, then a reset that comes
  /// sooner before one further away, then the name so the order is stable.
  private static func orderOfLimits(
    _ limits: [String: Limit]
  ) -> (String, String) -> Bool {
    func rank(_ name: String) -> Int {
      if name == "session" { return 0 }
      if name == "weekly" { return 1 }
      if name.hasPrefix("week ") { return 2 }
      return 3
    }
    return { left, right in
      let (leftRank, rightRank) = (rank(left), rank(right))
      if leftRank != rightRank { return leftRank < rightRank }
      let leftReset = limits[left]?.resetsAt ?? .distantFuture
      let rightReset = limits[right]?.resetsAt ?? .distantFuture
      if leftReset != rightReset { return leftReset < rightReset }
      return left < right
    }
  }

  /// `3h 07m`, `6d 9h`, `45m`, `now`.
  public static func countdown(_ interval: TimeInterval) -> String {
    let minutes = Int((interval / 60).rounded(.up))
    guard minutes > 0 else { return "now" }
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h \(String(format: "%02d", minutes % 60))m" }
    return "\(hours / 24)d \(hours % 24)h"
  }

  public static func money(_ amount: Double) -> String {
    "$" + String(format: amount == amount.rounded() ? "%.0f" : "%.2f", amount)
  }
}

public enum MaiProviderStatusError: LocalizedError, Equatable {
  case missingAPIKey(String)
  case http(Int, String)
  case unsupportedResponse

  public var errorDescription: String? {
    switch self {
    case .missingAPIKey(let provider):
      return "\(provider) has no API key configured, so its limits cannot be read."
    case .http(let code, let body):
      // 429 carries Retry-After; 401 means the stored key is no longer valid.
      return "\(code == 429 ? "Rate limited" : "HTTP \(code)"): \(body)"
    case .unsupportedResponse:
      return "The provider sent a status this version does not understand."
    }
  }
}

public enum MaiProviderStatusService {
  /// Reads one hosted provider's status. Returns nil for providers that do not
  /// publish one, such as a local model server.
  public static func status(
    for configuration: ConfiguredProvider,
    model: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    session: URLSession = .shared
  ) async throws -> MaiProviderStatus? {
    // An ACP provider is an agent with its own subscription, not an endpoint.
    if let command = configuration.options["command"]?.stringValue {
      return try await meter(
        command: command, arguments: configuration.options["args"]?.arrayValue?
          .compactMap(\.stringValue) ?? [], provider: configuration.id)
    }
    guard let host = configuration.baseURL?.host?.lowercased(), isOllamaCloud(host) else {
      return nil
    }
    guard let key = try configuration.resolvedAPIKey(environment: environment),
      !key.isEmpty
    else { throw MaiProviderStatusError.missingAPIKey(configuration.id) }
    // Three cheap calls at once: the plan and the spend history only label and
    // enrich the balance, so their failure never loses the limits themselves.
    async let plan = planName(apiKey: key, session: session)
    async let usage = usageRequests(apiKey: key, session: session)
    let balance = try await get(
      URL(string: "https://ollama.com/api/balance")!, apiKey: key, session: session)
    let (planName, requests) = await (plan, usage)
      let status = decoded(
      balance, provider: configuration.id, model: model ?? configuration.defaultModel, plan: planName,
      requestsLast7Days: requests.last7Days, requestsToday: requests.today)
    return status
  }

  /// `GET /api/usage` counts requests per day; on a credits plan it carries no
  /// tokens or money, so it only says how busy the account has been.
  static func usageRequests(apiKey: String, session: URLSession) async
    -> (last7Days: Int, today: Int)
  {
    guard let url = URL(string: "https://ollama.com/api/usage?range=7d"),
      let data = try? await get(url, apiKey: apiKey, session: session),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return (0, 0) }
    let totals = root["totals"] as? [String: Any] ?? [:]
    let week = (totals["request_count"] as? Int) ?? 0
    let buckets = root["buckets"] as? [[String: Any]] ?? []
    return (week, (buckets.last?["request_count"] as? Int) ?? 0)
  }

  /// An agent backend's own limits, on the platforms that can start it. A
  /// client that cannot — a phone — reads its host's answer instead.
  static func meter(
    command: String, arguments: [String], provider: String
  ) async throws -> MaiProviderStatus? {
    #if os(macOS) || os(Linux) || os(Windows)
      return try await MeteredAgentStatus.status(
        command: command, arguments: arguments, provider: provider)
    #else
      return nil
    #endif
  }

  /// Whether a configured provider is Ollama's cloud, whatever the id it was
  /// given, so `usage` works on a renamed provider too.
  public static func isOllamaCloud(_ host: String) -> Bool {
    host == "ollama.com" || host.hasSuffix(".ollama.com")
  }

  /// `POST /api/me` is undocumented but stable, and the plan only labels the
  /// answer; a failure there never fails the status itself.
  private static func planName(apiKey: String, session: URLSession) async -> String? {
    guard let url = URL(string: "https://ollama.com/api/me") else { return nil }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data("{}".utf8)
    request.timeoutInterval = 10
    guard let (data, response) = try? await session.data(for: request),
      let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let plan = object["Plan"] as? String, !plan.isEmpty
    else { return nil }
    return plan
  }

  static func get(_ url: URL, apiKey: String, session: URLSession) async throws -> Data {
    var request = URLRequest(url: url)
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.timeoutInterval = 15
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw MaiProviderStatusError.unsupportedResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      let body = String(decoding: data.prefix(200), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw MaiProviderStatusError.http(http.statusCode, body)
    }
    return data
  }

  /// Reads the balance body through `JSONSerialization` with every field
  /// optional: Ollama has changed this shape before, and numbers arrive as
  /// either numbers or strings.
  static func decoded(
    _ data: Data, provider: String, model: String?, plan: String?,
    requestsLast7Days: Int? = nil, requestsToday: Int? = nil
  ) -> MaiProviderStatus {
    let root = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    let included = root["included"] as? [String: Any] ?? [:]
    var status = MaiProviderStatus(provider: provider, plan: plan)
    func percent(_ object: Any?) -> MaiProviderStatus.Limit? {
      guard let object = object as? [String: Any],
        let remaining = number(object["remaining_percent"] ?? object["usage"])
      else { return nil }
      return .init(remainingPercent: 0...1 ~= remaining ? remaining * 100 : remaining,
        resetsAt: MaiProviderStatus.date(object["resets_at"] ?? object["resetsAt"]))
    }
    if let session = percent(included["session"]) { status.limits["session"] = session }
    if let weekly = percent(included["weekly"]) { status.limits["weekly"] = weekly }
    if let monthly = percent(included["monthly"]) { status.limits["monthly"] = monthly }
    if let remaining = number(included["balance_usd"] ?? included["balance_usd_remaining"]) {
      let allowance = number(included["allowance_usd"]) ?? remaining
      let period = included["period"] as? [String: Any]
      status.balances.append(
        .credits(remaining: remaining, allowance: allowance,
          resetsAt: MaiProviderStatus.date(period?["until"])))
    }
    if let purchased = root["purchased"] as? [String: Any],
      let amount = number(purchased["balance_usd"])
    {
      status.balances.append(.purchased(amount))
    }
    // Older builds put the same percentages under `limits`; nothing there is
    // reliable after the credits migration, but an account that still fills
    // it should not lose its session and weekly lines.
    if status.limits.isEmpty, let limits = root["limits"] as? [String: Any] {
      for name in ["session", "weekly", "monthly"] {
        if let limit = percent(limits[name]) { status.limits[name] = limit }
      }
    }
    return status
  }

  private static func number(_ raw: Any?) -> Double? {
    if let value = raw as? Double { return value }
    if let value = raw as? Int { return Double(value) }
    guard let text = (raw as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty
    else { return nil }
    return Double(text.replacingOccurrences(of: "$", with: "")
      .replacingOccurrences(of: ",", with: ""))
  }

}

extension MaiProviderStatus {
  /// An ISO 8601 timestamp, with or without fractional seconds, or nil.
  static func date(_ raw: Any?) -> Date? {
    let text: String
    if let value = raw as? String {
      text = value
    } else if let value = raw as? JSONValue {
      text = value.stringValue ?? ""
    } else {
      return nil
    }
    guard !text.isEmpty else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
  }
}
