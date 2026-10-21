import UIKit

/// The "PocketMai" entry in other apps' share sheets.
///
/// It has no composer of its own: whatever is shared is copied into the App
/// Group inbox and PocketMai is brought to the front, so the items land in the
/// chat composer or Webxdc app library as appropriate. When
/// the system refuses to open the app, the items stay queued and are imported
/// the next time PocketMai becomes active.
final class ShareViewController: UIViewController {
  private let card = UIView()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let statusLabel = UILabel()
  private var hasStarted = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor.black.withAlphaComponent(0.2)
    configureCard()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !hasStarted else { return }
    hasStarted = true
    Task { await importSharedItems() }
  }

  // MARK: - Import

  private func importSharedItems() async {
    let extensionItems = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
    let items = await SharedItemLoader.items(in: extensionItems)
    guard !items.isEmpty else {
      await finish(message: "Nothing could be shared.")
      return
    }

    SharedInbox.enqueue(items)
    statusLabel.text =
      items.count == 1 ? "Sending to PocketMai..." : "Sending \(items.count) items..."

    if await openHostApp() {
      extensionContext?.completeRequest(returningItems: nil)
      return
    }
    await finish(message: "Saved. Open PocketMai to import.")
  }

  private func openHostApp() async -> Bool {
    guard let context = extensionContext else { return false }
    let url = PocketMaiDeepLink.url(for: .importSharedContent)
    return await withCheckedContinuation { continuation in
      // The system calls back on its own queue, so the handler must not
      // inherit the main actor.
      let handler: @Sendable (Bool) -> Void = { opened in
        continuation.resume(returning: opened)
      }
      context.open(url, completionHandler: handler)
    }
  }

  private func finish(message: String) async {
    spinner.stopAnimating()
    statusLabel.text = message
    try? await Task.sleep(for: .milliseconds(900))
    extensionContext?.completeRequest(returningItems: nil)
  }

  // MARK: - Interface

  private func configureCard() {
    card.backgroundColor = .secondarySystemBackground
    card.layer.cornerRadius = 18
    card.layer.cornerCurve = .continuous
    card.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(card)

    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.startAnimating()

    statusLabel.text = "Sending to PocketMai..."
    statusLabel.font = .preferredFont(forTextStyle: .callout)
    statusLabel.textColor = .label
    statusLabel.numberOfLines = 2
    statusLabel.translatesAutoresizingMaskIntoConstraints = false

    let row = UIStackView(arrangedSubviews: [spinner, statusLabel])
    row.axis = .horizontal
    row.spacing = 12
    row.alignment = .center
    row.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(row)

    NSLayoutConstraint.activate([
      card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      card.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
      card.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
      row.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
      row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
      row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
      row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
    ])
  }
}
