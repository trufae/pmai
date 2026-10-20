import Foundation

/// Built-in Speech API choices; these do not require a voice-discovery request.
/// https://developers.openai.com/api/docs/guides/text-to-speech#voice-options
public enum OpenAISpeech {
  public static let defaultModel = "gpt-4o-mini-tts"
  public static let models = [defaultModel, "gpt-4o-mini-tts-2025-12-15", "tts-1", "tts-1-hd"]
  public static let voices = [
    "alloy", "ash", "ballad", "coral", "echo", "fable", "nova", "onyx", "sage",
    "shimmer", "verse", "marin", "cedar",
  ]

  public static func isDirectEndpoint(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "https" && url.host?.lowercased() == "api.openai.com"
  }

  public static func voices(for model: String) -> [String] {
    let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
    if model == "tts-1" || model.hasPrefix("tts-1-") {
      return voices.filter { !["ballad", "verse", "marin", "cedar"].contains($0) }
    }
    return voices
  }

  public static func validate(voice: String, model: String) throws {
    guard voices(for: model).contains(voice) else {
      throw OpenAICompatibleProviderError.invalidResponse(
        "Voice '\(voice)' is not available for OpenAI speech model '\(model)'. "
          + "Choose a supported voice in Settings > Voices.")
    }
  }

  /// A conservative UTF-8 budget stays within the 4096-character Speech API
  /// limit and mini-TTS's 2000-token limit, including non-English text. Keep
  /// whitespace so joining the queued chunks reproduces the original input.
  public static func textChunks(_ text: String, maximumUTF8Bytes: Int = 2_000) -> [String] {
    let budget = max(4, maximumUTF8Bytes)
    let scalars = text.unicodeScalars
    var start = scalars.startIndex
    var chunks: [String] = []
    while start < scalars.endIndex {
      var end = start
      var wordBoundary = start
      var bytes = 0
      while end < scalars.endIndex {
        let scalar = scalars[end]
        guard bytes + scalar.utf8.count <= budget else { break }
        bytes += scalar.utf8.count
        end = scalars.index(after: end)
        if scalar.properties.isWhitespace { wordBoundary = end }
      }
      if end != scalars.endIndex, wordBoundary > start { end = wordBoundary }
      chunks.append(String(scalars[start..<end]))
      start = end
    }
    return chunks
  }
}
