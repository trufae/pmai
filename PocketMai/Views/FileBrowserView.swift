import MaiStandardTools
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct FileBrowserView: View {
  @EnvironmentObject private var appStore: AppStore
  @State var location: FileBrowserLocation

  var body: some View {
    NavigationStack {
      FileBrowserDirectoryView(location: location, store: appStore) { url in
        location = .local(.custom(rootURL: url, displayName: url.lastPathComponent))
      }
      .id(location.id)
    }
  }
}

private struct FileBrowserDirectoryView: View {
  @EnvironmentObject private var appStore: AppStore
  @Environment(\.dismiss) private var dismiss
  @StateObject private var browser: WorkspaceFileBrowser
  private let onChooseFolder: (URL) -> Void
  @State private var search = ""
  @State private var showingFolderPicker = false
  @State private var showingUploadPicker = false
  @State private var showingNewFolder = false
  @State private var showingReplace = false
  @State private var folderName = ""
  @State private var pendingUploads: [URL] = []
  @State private var pendingDownload: WorkspaceFileEntry?

  init(location: FileBrowserLocation, store: AppStore, onChooseFolder: @escaping (URL) -> Void) {
    _browser = StateObject(
      wrappedValue: WorkspaceFileBrowser(
        location: location,
        isOffline: { store.settings.isOffline }))
    self.onChooseFolder = onChooseFolder
  }

  var body: some View {
    presentations
      .task { browser.browse() }
      .onDisappear { browser.close() }
      .onChange(of: browser.showHidden) { _, _ in browser.browse() }
      .onChange(of: appStore.settings.isOffline) { _, offline in
        if offline && browser.location.isRemote { browser.cancel() }
      }
  }

  private var screen: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text(browser.location.title).font(.subheadline.weight(.semibold))
          if !browser.writeEnabled { Text("Read Only").font(.caption).foregroundStyle(.secondary) }
        }
        Text(browser.path).font(.caption.monospaced()).foregroundStyle(.secondary)
          .textSelection(.enabled).lineLimit(3)
        if let status = browser.status {
          HStack {
            if let progress = browser.progress {
              ProgressView(value: progress)
            } else {
              ProgressView().controlSize(.small)
            }
            Text(status).font(.caption)
            Button("Cancel", action: browser.cancel)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading).padding()
      List {
        ForEach(
          browser.entries.filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
          }
        ) { entry in
          Button {
            browser.open(entry)
          } label: {
            HStack(spacing: 12) {
              Image(systemName: icon(entry)).frame(width: 24).foregroundStyle(Color.accentColor)
              VStack(alignment: .leading, spacing: 4) {
                Text(entry.name).foregroundStyle(.primary).lineLimit(2)
                Text(
                  entry.isDirectory
                    ? "Folder"
                    : ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file)
                )
                .font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              if entry.isSymbolicLink { Image(systemName: "link").foregroundStyle(.secondary) }
              if entry.isDirectory {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
              }
            }
          }
          .disabled(browser.isBusy)
          .contextMenu {
            Button("Copy Path", systemImage: "doc.on.doc") {
              UIPasteboard.general.string = entry.path
            }
            Button(
              entry.isDirectory ? "Open Folder" : "Preview",
              systemImage: entry.isDirectory ? "folder" : "eye"
            ) {
              browser.open(entry)
            }.disabled(browser.isBusy)
            if !entry.isDirectory {
              Button("Download…", systemImage: "arrow.down.doc") { browser.save(entry) }
                .disabled(browser.isBusy)
            }
          }
        }
        if browser.nextOffset != nil {
          Button("Load More Files") { browser.browse(append: true) }.disabled(browser.isBusy)
        } else if browser.entries.isEmpty && !browser.isBusy && browser.error == nil {
          ContentUnavailableView("Empty Folder", systemImage: "folder")
        }
      }
      .listStyle(.plain)
      .refreshable {
        browser.browse()
        await browser.operation?.value
      }
    }
    .navigationTitle("Files").navigationBarTitleDisplayMode(.inline)
    .searchable(text: $search, prompt: "Filter files")
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
      ToolbarItem(placement: .topBarTrailing) {
        Menu("File Actions", systemImage: "ellipsis.circle") {
          Button("Copy Folder Path", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = browser.path
          }
          Button("Refresh", systemImage: "arrow.clockwise") { browser.browse() }
          Toggle("Show Hidden Files", isOn: $browser.showHidden)
          Divider()
          Button("Choose Local Folder…", systemImage: "folder.badge.gearshape") {
            showingFolderPicker = true
          }
        }
        .disabled(browser.isBusy)
      }
      ToolbarItem(placement: .bottomBar) {
        Button("Parent Folder", systemImage: "chevron.up", action: browser.goUp)
          .disabled(!browser.canGoUp)
      }
      ToolbarItem(placement: .bottomBar) { Spacer() }
      ToolbarItem(placement: .bottomBar) {
        Button("New Folder", systemImage: "folder.badge.plus") {
          folderName = ""
          showingNewFolder = true
        }
        .disabled(browser.isBusy || !browser.writeEnabled)
      }
      ToolbarItem(placement: .bottomBar) {
        Button("Upload Files", systemImage: "arrow.up.doc") { showingUploadPicker = true }
          .disabled(browser.isBusy || !browser.writeEnabled)
      }
    }
  }

  private var presentations: some View {
    screen
      .fileImporter(isPresented: $showingFolderPicker, allowedContentTypes: [.folder]) { result in
        do { onChooseFolder(try result.get()) } catch { browser.error = error.localizedDescription }
      }
      .fileImporter(
        isPresented: $showingUploadPicker, allowedContentTypes: [.data],
        allowsMultipleSelection: true
      ) { result in
        do {
          let urls = try result.get()
          if urls.contains(where: { url in
            browser.entries.contains { $0.name == url.lastPathComponent }
          }) {
            pendingUploads = urls
            showingReplace = true
          } else {
            browser.upload(urls)
          }
        } catch { browser.error = error.localizedDescription }
      }
      .alert("New Folder", isPresented: $showingNewFolder) {
        TextField("Folder name", text: $folderName)
        Button("Cancel", role: .cancel) {}
        Button("Create") { browser.createDirectory(folderName) }.disabled(folderName.isEmpty)
      }
      .alert("Replace existing files?", isPresented: $showingReplace) {
        Button("Cancel", role: .cancel) { pendingUploads = [] }
        Button("Replace and Upload", role: .destructive) {
          browser.upload(pendingUploads, overwrite: true)
          pendingUploads = []
        }
      } message: {
        Text(
          "Files with matching names in this folder will be replaced after the upload completes.")
      }
      .alert(
        "File Operation Failed",
        isPresented: Binding(get: { browser.error != nil }, set: { if !$0 { browser.error = nil } })
      ) {
        Button("OK", role: .cancel) { browser.error = nil }
      } message: {
        Text(browser.error ?? "")
      }
      .sheet(
        item: Binding(get: { browser.preview }, set: { if $0 == nil { browser.clearPreview() } }),
        onDismiss: {
          if let entry = pendingDownload {
            pendingDownload = nil
            browser.save(entry)
          }
        }
      ) { file in
        FileBrowserPreview(
          file: file,
          browser: browser,
          appearance: appStore.settings.appearance,
          onDownload: {
            pendingDownload = browser.entries.first { $0.path == file.originalPath }
            browser.clearPreview()
          })
      }
      .sheet(
        item: Binding(get: { browser.download }, set: { if $0 == nil { browser.clearDownload() } })
      ) { file in
        FileBrowserExport(url: file.url, onFinish: browser.clearDownload)
      }
  }

  private func icon(_ entry: WorkspaceFileEntry) -> String {
    if entry.isDirectory { return "folder.fill" }
    let type = UTType(filenameExtension: URL(fileURLWithPath: entry.name).pathExtension)
    if type?.conforms(to: .image) == true { return "photo" }
    if type?.conforms(to: .audio) == true { return "waveform" }
    if type?.conforms(to: .movie) == true { return "film" }
    return "doc"
  }
}

private struct FileBrowserPreview: View {
  let file: BrowserFile
  @ObservedObject var browser: WorkspaceFileBrowser
  let appearance: AppearanceSettings
  let onDownload: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var content: Content?
  @State private var loadError: String?

  private enum Content {
    case text(String)
    case image(UIImage, Data)
    case quickLook
    case binary(String)
  }

  var body: some View {
    Group {
      switch content {
      case .text(let text):
        MessageTextSelectionSheet(
          title: file.url.lastPathComponent,
          text: text,
          appearance: appearance,
          initialFontSize: appearance.fontSize,
          initialLineSpacing: appearance.lineSpacing,
          fontFamily: appearance.fontFamily(for: .user),
          isEditable: browser.writeEnabled && !file.isPartial,
          initiallyShowingPreview: ["md", "markdown", "mdown"].contains(
            file.url.pathExtension.lowercased()),
          onSave: { text in try await browser.update(file, text: text) })
      case .image(let image, let data):
        MessageImageFullscreenView(image: image, imageData: data)
      default:
        NavigationStack {
          Group {
            switch content {
            case .quickLook:
              FileQuickLook(url: file.url)
            case .binary(let text):
              ScrollView {
                Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                  .frame(maxWidth: .infinity, alignment: .leading).padding()
              }
            default:
              if let loadError {
                ContentUnavailableView(
                  "Could Not Preview File", systemImage: "doc", description: Text(loadError))
              } else {
                ProgressView("Loading preview…")
              }
            }
          }
          .navigationTitle(file.url.lastPathComponent).navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
          }
        }
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(alignment: .leading, spacing: 12) {
        if file.isPartial {
          Text(
            "Showing the beginning of this \(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)) file. Download it for the full contents."
          )
          .font(.callout).foregroundStyle(.secondary)
        }
        HStack {
          Button("Copy Path", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = file.originalPath
          }
          Spacer()
          Button("Download", systemImage: "arrow.down.doc", action: onDownload)
        }
      }
      .disabled(browser.isBusy)
      .padding().background(.bar)
    }
    .task(id: file.id) { await loadContent() }
  }

  private func loadContent() async {
    do {
      let url = file.url
      let data = try await Task.detached(priority: .userInitiated) {
        try Data(contentsOf: url)
      }.value
      try Task.checkCancellation()
      let type = UTType(filenameExtension: url.pathExtension)
      let prefersQuickLook = [UTType.image, .audiovisualContent, .pdf, .rtf].contains { format in
        type?.conforms(to: format) == true
      }
      let canQuickLook = !file.isPartial && QLPreviewController.canPreview(url as NSURL)
      if !file.isPartial,
        let image = await AttachmentImageLoader.decodeImageData(data, maxPixelDimension: 4_096)
      {
        content = .image(image, data)
      } else if prefersQuickLook && canQuickLook {
        content = .quickLook
      } else if let text = BrowserFile.textContent(data, isPartial: file.isPartial) {
        content = .text(text)
      } else if canQuickLook {
        content = .quickLook
      } else {
        content = .binary(
          data.prefix(4096).enumerated().map { index, byte in
            (index % 16 == 0 ? String(format: "\n%08x  ", index) : "")
              + String(format: "%02x ", byte)
          }.joined())
      }
    } catch is CancellationError {
    } catch {
      loadError = error.localizedDescription
    }
  }
}

private struct FileQuickLook: UIViewControllerRepresentable {
  let url: URL
  final class Coordinator: NSObject, QLPreviewControllerDataSource {
    let url: URL
    init(_ url: URL) { self.url = url }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int)
      -> any QLPreviewItem
    { url as NSURL }
  }
  func makeCoordinator() -> Coordinator { Coordinator(url) }
  func makeUIViewController(context: Context) -> QLPreviewController {
    let controller = QLPreviewController()
    controller.dataSource = context.coordinator
    return controller
  }
  func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
}

private struct FileBrowserExport: UIViewControllerRepresentable {
  let url: URL
  let onFinish: () -> Void
  final class Coordinator: NSObject, UIDocumentPickerDelegate {
    let onFinish: () -> Void
    init(_ onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func documentPicker(
      _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
    ) { onFinish() }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onFinish() }
  }
  func makeCoordinator() -> Coordinator { Coordinator(onFinish) }
  func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
    let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    picker.delegate = context.coordinator
    return picker
  }
  func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}
