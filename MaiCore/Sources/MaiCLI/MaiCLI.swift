/// Shared entry point for the terminal executable and the Mac app's ACP worker.
public enum MaiCLI {
  static let version = "1.15.2"

  public static func main() async {
    await run()
  }
}
