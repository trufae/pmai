import Foundation

public enum AudioAPIError: LocalizedError, Sendable {
  case invalidRequest(String)
  public var errorDescription: String? {
    switch self {
    case .invalidRequest(let message): return message
    }
  }
}

/// Binary-safe multipart parsing shared by HTTP hosts and transcription clients.
public struct AudioMultipart: Sendable {
  public struct Part: Sendable {
    public var name: String
    public var filename: String?
    public var contentType: String
    public var data: Data
    public init(
      name: String, filename: String? = nil, contentType: String = "text/plain", data: Data
    ) {
      self.name = name
      self.filename = filename
      self.contentType = contentType
      self.data = data
    }
    public var text: String { String(decoding: data, as: UTF8.self) }
  }
  public static let maximumBytes = 25 * 1024 * 1024
  public var parts: [Part]
  public init(parts: [Part]) { self.parts = parts }
  public func field(_ name: String) -> String? { parts.first { $0.name == name }?.text }

  public init(data: Data, contentType: String) throws {
    guard data.count <= Self.maximumBytes,
      contentType.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
        == "multipart/form-data",
      let boundary = contentType.components(separatedBy: ";").dropFirst().compactMap({
        item -> String? in
        let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
        guard pair.count == 2,
          pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "boundary"
        else { return nil }
        return pair[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(
          in: CharacterSet(charactersIn: "\""))
      }).first, !boundary.isEmpty, boundary.utf8.count <= 200,
      !boundary.utf8.contains(13), !boundary.utf8.contains(10)
    else {
      throw AudioAPIError.invalidRequest(
        "Expected multipart/form-data with a boundary (maximum 25 MiB).")
    }
    let marker = Data("--\(boundary)".utf8)
    guard data.starts(with: marker) else {
      throw AudioAPIError.invalidRequest("Invalid multipart boundary.")
    }
    let separator = Data("\r\n--\(boundary)".utf8)
    var cursor = marker.count
    var decoded: [Part] = []
    while true {
      if data[cursor...].starts(with: Data("--".utf8)) { break }
      guard data[cursor...].starts(with: Data("\r\n".utf8)) else {
        throw AudioAPIError.invalidRequest("Invalid multipart delimiter.")
      }
      cursor += 2
      guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8), in: cursor..<data.endIndex),
        headerEnd.lowerBound - cursor <= 16_384,
        let header = String(data: data[cursor..<headerEnd.lowerBound], encoding: .utf8)
      else { throw AudioAPIError.invalidRequest("Invalid multipart headers.") }
      let start = headerEnd.upperBound
      var end: Range<Data.Index>?
      var search = start
      while let candidate = data.range(of: separator, in: search..<data.endIndex) {
        let tail = data[candidate.upperBound...]
        if tail.starts(with: Data("--".utf8)) || tail.starts(with: Data("\r\n".utf8)) {
          end = candidate
          break
        }
        search = candidate.upperBound
      }
      guard let end else { throw AudioAPIError.invalidRequest("Multipart body is incomplete.") }
      var headers: [String: String] = [:]
      for line in header.components(separatedBy: "\r\n") {
        let pair = line.split(separator: ":", maxSplits: 1).map(String.init)
        if pair.count == 2 {
          headers[pair[0].lowercased()] = pair[1].trimmingCharacters(in: .whitespaces)
        }
      }
      let disposition = headers["content-disposition"] ?? ""
      func parameter(_ key: String) -> String? {
        for part in disposition.components(separatedBy: ";").dropFirst() {
          let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            .map(String.init)
          if pair.count == 2, pair[0] == key {
            return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
          }
        }
        return nil
      }
      guard let name = parameter("name"), !decoded.contains(where: { $0.name == name }) else {
        throw AudioAPIError.invalidRequest("Multipart fields must have unique names.")
      }
      decoded.append(
        Part(
          name: name, filename: parameter("filename"),
          contentType: headers["content-type"] ?? "application/octet-stream",
          data: Data(data[start..<end.lowerBound])))
      guard decoded.count <= 32 else {
        throw AudioAPIError.invalidRequest("Too many multipart fields.")
      }
      cursor = end.upperBound
    }
    parts = decoded
  }

  public func encoded(boundary: String) throws -> Data {
    guard !boundary.isEmpty, boundary.utf8.count <= 200 else {
      throw AudioAPIError.invalidRequest("Invalid multipart boundary.")
    }
    var data = Data()
    for part in parts {
      for value in [part.name, part.filename ?? "", part.contentType, boundary] {
        guard !value.utf8.contains(13), !value.utf8.contains(10), !value.utf8.contains(34) else {
          throw AudioAPIError.invalidRequest("Invalid multipart field metadata.")
        }
      }
      var head = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(part.name)\""
      if let filename = part.filename { head += "; filename=\"\(filename)\"" }
      data.append(Data((head + "\r\nContent-Type: \(part.contentType)\r\n\r\n").utf8))
      guard part.data.count <= Self.maximumBytes,
        data.count <= Self.maximumBytes - part.data.count
      else {
        throw AudioAPIError.invalidRequest("Audio upload exceeds 25 MiB.")
      }
      data.append(part.data)
      data.append(Data("\r\n".utf8))
    }
    data.append(Data("--\(boundary)--\r\n".utf8))
    guard data.count <= Self.maximumBytes else {
      throw AudioAPIError.invalidRequest("Audio upload exceeds 25 MiB.")
    }
    return data
  }
}

public struct AudioAPIResponse: Sendable {
  public var contentType: String
  public var body: Data
  public var stream: AsyncThrowingStream<Data, Error>?
  public init(
    contentType: String, body: Data = Data(), stream: AsyncThrowingStream<Data, Error>? = nil
  ) {
    self.contentType = contentType
    self.body = body
    self.stream = stream
  }
}

public struct AudioSpeechRequest: Codable, Sendable {
  public var model: String
  public var input: String
  public var voice: String
  public var response_format: String?
  public var speed: Double?
  public var stream_format: String?
}
