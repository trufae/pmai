/// Shared entry point for the terminal executable and the Mac app's ACP worker.
public enum MaiCLI {
  static let version = "1.14.6"

  public static func main() async {
    await run()
  }
}
