import UIKit
import UniformTypeIdentifiers

/// 系统分享面板里的 Flashbyte 入口。
///
/// 扩展只负责把分享内容复制到 App Group 的共享目录并写一份清单，主应用打开
/// （或被唤起）后通过 `flashbyte/ios_sharing` 通道取走。复制放在扩展里完成，
/// 主应用不需要访问扩展的临时目录。
final class ShareViewController: UIViewController {
  private let appGroupIdentifier = "group.com.flashbyte"
  private let inboxFolderName = "ShareInbox"
  private let manifestFileName = "manifest.json"

  private let statusLabel = UILabel()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private var hasStarted = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    preferredContentSize = CGSize(width: 320, height: 160)

    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.textAlignment = .center
    statusLabel.numberOfLines = 0
    statusLabel.font = .preferredFont(forTextStyle: .body)
    statusLabel.text = Self.preferredText(
      zh: "正在发送到 Flashbyte…",
      en: "Sending to Flashbyte…"
    )

    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.hidesWhenStopped = true

    let stack = UIStackView(arrangedSubviews: [spinner, statusLabel])
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)

    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      stack.leadingAnchor.constraint(
        greaterThanOrEqualTo: view.leadingAnchor,
        constant: 24
      ),
      stack.trailingAnchor.constraint(
        lessThanOrEqualTo: view.trailingAnchor,
        constant: -24
      ),
    ])
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !hasStarted else { return }
    hasStarted = true
    spinner.startAnimating()
    startProcessing()
  }

  private func startProcessing() {
    guard
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupIdentifier
      )
    else {
      finish(success: false)
      return
    }

    let inbox = container.appendingPathComponent(
      inboxFolderName,
      isDirectory: true
    )
    do {
      try FileManager.default.createDirectory(
        at: inbox,
        withIntermediateDirectories: true
      )
    } catch {
      finish(success: false)
      return
    }

    let attachments = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
    let providers = attachments.flatMap { $0.attachments ?? [] }
    process(providers: providers, index: 0, inbox: inbox, entries: [])
  }

  private func process(
    providers: [NSItemProvider],
    index: Int,
    inbox: URL,
    entries: [[String: Any]]
  ) {
    guard index < providers.count else {
      appendManifest(entries: entries, inbox: inbox)
      finish(success: !entries.isEmpty)
      return
    }

    load(provider: providers[index], inbox: inbox) { [weak self] entry in
      guard let self else { return }
      var next = entries
      if let entry {
        next.append(entry)
      }
      self.process(
        providers: providers,
        index: index + 1,
        inbox: inbox,
        entries: next
      )
    }
  }

  private func load(
    provider: NSItemProvider,
    inbox: URL,
    completion: @escaping ([String: Any]?) -> Void
  ) {
    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
      provider.loadItem(
        forTypeIdentifier: UTType.fileURL.identifier,
        options: nil
      ) { item, _ in
        guard let url = Self.fileURL(from: item) else {
          completion(nil)
          return
        }
        self.copyFile(
          at: url,
          inbox: inbox,
          clipboard: false,
          completion: completion
        )
      }
      return
    }

    if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
      provider.loadFileRepresentation(
        forTypeIdentifier: UTType.image.identifier
      ) { url, _ in
        if let url {
          self.copyFile(
            at: url,
            inbox: inbox,
            clipboard: false,
            completion: completion
          )
          return
        }
        // 部分来源只提供 UIImage，不提供文件表示。
        provider.loadItem(
          forTypeIdentifier: UTType.image.identifier,
          options: nil
        ) { item, _ in
          guard
            let image = item as? UIImage,
            let data = image.jpegData(compressionQuality: 0.95)
          else {
            completion(nil)
            return
          }
          self.writeData(
            data,
            name: "Image.jpg",
            inbox: inbox,
            clipboard: false,
            completion: completion
          )
        }
      }
      return
    }

    if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
      provider.loadFileRepresentation(
        forTypeIdentifier: UTType.movie.identifier
      ) { url, _ in
        guard let url else {
          completion(nil)
          return
        }
        self.copyFile(
          at: url,
          inbox: inbox,
          clipboard: false,
          completion: completion
        )
      }
      return
    }

    if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
      provider.loadItem(
        forTypeIdentifier: UTType.url.identifier,
        options: nil
      ) { item, _ in
        let value: String?
        if let url = item as? URL {
          value = url.absoluteString
        } else if let text = item as? String {
          value = text
        } else {
          value = nil
        }
        guard let text = value else {
          completion(nil)
          return
        }
        self.writeText(text, inbox: inbox, completion: completion)
      }
      return
    }

    if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
      provider.loadItem(
        forTypeIdentifier: UTType.plainText.identifier,
        options: nil
      ) { item, _ in
        let value = (item as? String) ?? (item as? NSAttributedString)?.string
        guard let text = value else {
          completion(nil)
          return
        }
        self.writeText(text, inbox: inbox, completion: completion)
      }
      return
    }

    completion(nil)
  }

  private static func fileURL(from item: NSSecureCoding?) -> URL? {
    if let url = item as? URL {
      return url
    }
    if let data = item as? Data {
      return URL(dataRepresentation: data, relativeTo: nil)
    }
    if let text = item as? String {
      return URL(string: text)
    }
    return nil
  }

  private func copyFile(
    at source: URL,
    inbox: URL,
    clipboard: Bool,
    completion: @escaping ([String: Any]?) -> Void
  ) {
    let name = source.lastPathComponent
    guard !name.isEmpty else {
      completion(nil)
      return
    }

    let storedName = UUID().uuidString + "-" + name
    let destination = inbox.appendingPathComponent(storedName)
    do {
      try? FileManager.default.removeItem(at: destination)
      try FileManager.default.copyItem(at: source, to: destination)
      completion(["name": name, "file": storedName, "clipboard": clipboard])
    } catch {
      completion(nil)
    }
  }

  private func writeText(
    _ text: String,
    inbox: URL,
    completion: @escaping ([String: Any]?) -> Void
  ) {
    let isChinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
    let name = isChinese ? "粘贴板文本.txt" : "Clipboard.txt"
    let storedName = UUID().uuidString + "-" + name
    let destination = inbox.appendingPathComponent(storedName)
    do {
      try text.write(to: destination, atomically: true, encoding: .utf8)
      completion(["name": name, "file": storedName, "clipboard": true])
    } catch {
      completion(nil)
    }
  }

  private func writeData(
    _ data: Data,
    name: String,
    inbox: URL,
    clipboard: Bool,
    completion: @escaping ([String: Any]?) -> Void
  ) {
    let storedName = UUID().uuidString + "-" + name
    let destination = inbox.appendingPathComponent(storedName)
    do {
      try data.write(to: destination, options: .atomic)
      completion(["name": name, "file": storedName, "clipboard": clipboard])
    } catch {
      completion(nil)
    }
  }

  private func appendManifest(entries: [[String: Any]], inbox: URL) {
    let manifestURL = inbox.appendingPathComponent(manifestFileName)
    var allEntries: [[String: Any]] = []
    if
      let data = try? Data(contentsOf: manifestURL),
      let existing = try? JSONSerialization.jsonObject(with: data)
        as? [[String: Any]]
    {
      allEntries = existing
    }
    allEntries.append(contentsOf: entries)
    guard
      let data = try? JSONSerialization.data(withJSONObject: allEntries)
    else {
      return
    }
    try? data.write(to: manifestURL, options: .atomic)
  }

  private func finish(success: Bool) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.spinner.stopAnimating()
      self.statusLabel.text = success
        ? Self.preferredText(
          zh: "已保存到 Flashbyte，打开应用继续发送",
          en: "Saved to Flashbyte. Open the app to continue."
        )
        : Self.preferredText(
          zh: "分享失败，请打开 Flashbyte 重试",
          en: "Share failed. Open Flashbyte and try again."
        )

      if success, let url = URL(string: "flashbyte://share") {
        self.extensionContext?.open(url, completionHandler: nil)
      }

      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.extensionContext?.completeRequest(
          returningItems: nil,
          completionHandler: nil
        )
      }
    }
  }

  private static func preferredText(zh: String, en: String) -> String {
    let isChinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
    return isChinese ? zh : en
  }
}
