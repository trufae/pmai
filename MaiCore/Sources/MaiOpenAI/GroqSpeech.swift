import Foundation

/// https://console.groq.com/docs/text-to-speech/orpheus
public enum GroqSpeech {
  public static let defaultSpeechModel = "canopylabs/orpheus-v1-english"
  public static let defaultTranscriptionModel = "whisper-large-v3-turbo"
  public static let speechModels = [defaultSpeechModel, "canopylabs/orpheus-arabic-saudi"]
  public static let transcriptionModels = [defaultTranscriptionModel, "whisper-large-v3"]

  public static func isDirectEndpoint(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "https" && url.host?.lowercased() == "api.groq.com"
  }

  public static func voices(for model: String) -> [String] {
    switch model {
    case defaultSpeechModel: return ["autumn", "diana", "hannah", "austin", "daniel", "troy"]
    case "canopylabs/orpheus-arabic-saudi":
      return ["abdullah", "fahad", "sultan", "lulwa", "noura", "aisha"]
    default: return []
    }
  }
}
