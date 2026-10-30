// 应用内更新：从 Kitty Tools 的 App/Updater.swift 摘出核心（读 latest release、比版本号、下载、验签、换掉、重新打开），
// 去掉它接刘海岛、菜单栏角标的部分。读本仓库 github.com/YyAdnBug/kitty-box 的 latest release（tag macos-v*）。
// 打开 App 10 秒后查一次；App 菜单「检查更新…」和关于窗口也能查。有新版本时首页顶上一条、关于窗口里「更新并重新打开」。
// 更新 = 下载 release 里的 *_arm64.zip → ditto 解到 App 所在卷的临时目录 → 校验 bundle id、版本号和签名（Apple 签发、
// 本团队 HTX9F4KG39 的证书）→ 原子地换掉正在运行的 .app → 等本进程退出后重新打开。解包、验签交给系统的 ditto / codesign，
// 在进程外跑。App 自己用 URLSession 下载的文件不带隔离标记，换上的新版不会再被 Gatekeeper 拦。
// 只有正式版（bundle id com.yy.kitty-box）更新：Debug 版的 bundle id 不同，装过去会把 Dev 换成正式版。

import AppKit
import Observation

@Observable final class Updater {
  struct Release: Equatable {
    let version: String
    /// 更新包（*_arm64.zip）
    let archive: URL
    /// 发布页（看更新内容）
    let page: URL
  }

  enum State: Equatable {
    case idle
    case checking
    case upToDate
    case available(Release)
    case installing(Release)
    case failed(String)
  }

  static let shared = Updater()

  private(set) var state = State.idle
  /// 更新包下了多少（0…1）；nil = 没在下载，或服务器没给大小
  private(set) var progress: Double?

  static let bundleID = "com.yy.kitty-box"
  static let releasesPage = URL(string: "https://github.com/YyAdnBug/kitty-box/releases")!
  private static let latest = URL(
    string: "https://api.github.com/repos/YyAdnBug/kitty-box/releases/latest")!
  /// 新包必须满足的签名要求：同一个 bundle id、Apple 签发、本团队的证书
  static let requirement =
    "=identifier \"\(bundleID)\" and anchor apple generic and certificate leaf[subject.OU] = \"HTX9F4KG39\""

  /// 正式版才更新（Debug 版 bundle id 不同）
  var isSupported: Bool { Bundle.main.bundleIdentifier == Self.bundleID }

  /// 有新版本时是它（侧边栏底下那张小卡）
  var available: Release? {
    if case .available(let release) = state { release } else { nil }
  }

  /// 打开 App 10 秒后查一次（刚开机网络可能还没好；没查成也不提示）
  func start() {
    guard isSupported else { return }
    Task {
      try? await Task.sleep(for: .seconds(10))
      if case .idle = state { await check() }
    }
  }

  func check() async {
    guard isSupported else {
      state = .failed("开发版不检查更新。")
      return
    }
    if case .checking = state { return }
    if case .installing = state { return }
    state = .checking
    do {
      var request = URLRequest(url: Self.latest)
      request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
      let (data, _) = try await URLSession.shared.data(for: request)
      let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
      if let release = try Self.release(from: data), Self.isNewer(release.version, than: current) {
        state = .available(release)
      } else {
        state = .upToDate
      }
    } catch {
      state = .failed("没查成：" + error.localizedDescription)
    }
  }

  func install() async {
    guard case .available(let release) = state else { return }
    state = .installing(release)
    progress = nil
    do {
      try await Self.replace(Bundle.main.bundleURL, with: release) { fraction in
        let percent = (fraction * 100).rounded() / 100
        Task { @MainActor in
          if Updater.shared.progress != percent { Updater.shared.progress = percent }
        }
      }
      try Self.relaunch(Bundle.main.bundleURL)
      NSApp.terminate(nil)
    } catch {
      progress = nil
      state = .failed(error.localizedDescription)
    }
  }

  // MARK: 纯函数

  /// GitHub「latest release」的 JSON → 版本、更新包、发布页。不是 macos-v* 的 tag、没有 https 的 *_arm64.zip 时 nil
  nonisolated static func release(from data: Data) throws -> Release? {
    struct Payload: Decodable {
      struct Asset: Decodable {
        let name: String
        let browserDownloadUrl: URL
      }
      let tagName: String
      let htmlUrl: URL
      let assets: [Asset]
    }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let payload = try decoder.decode(Payload.self, from: data)
    let prefix = "macos-v"
    guard payload.tagName.hasPrefix(prefix),
      let asset = payload.assets.first(where: { $0.name.hasSuffix("_arm64.zip") }),
      asset.browserDownloadUrl.scheme == "https"
    else { return nil }
    return Release(
      version: String(payload.tagName.dropFirst(prefix.count)), archive: asset.browserDownloadUrl,
      page: payload.htmlUrl)
  }

  /// 按数字逐段比（0.1.10 比 0.1.9 新）
  nonisolated static func isNewer(_ version: String, than current: String) -> Bool {
    version.compare(current, options: .numeric) == .orderedDescending
  }

  // MARK: 安装

  /// 下载更新包，解到 target 所在卷的临时目录，校验 bundle id、版本号和签名，再原子地换掉 target。
  /// 从 DMG 里、或没拖进「应用程序」就打开（系统把它挪到只读的随机路径）时换不了；标准（非管理员）账户写不了「应用程序」
  static func replace(
    _ target: URL, with release: Release, progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    let folderURL = target.deletingLastPathComponent()
    let folder = folderURL.path
    let readOnly = (try? folderURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?
      .volumeIsReadOnly
    if folder.contains("/AppTranslocation/") || readOnly == true {
      throw UpdateError("请先把 Kitty Box 拖进「应用程序」，从那里打开后再更新")
    }
    guard FileManager.default.isWritableFile(atPath: folder) else {
      throw UpdateError("没有权限替换「\(folder)」里的 App：请用管理员账户更新，或到发布页下载后手动替换")
    }
    let (zip, response) = try await URLSession.shared.download(
      from: release.archive, delegate: DownloadWatcher(report: progress))
    defer { try? FileManager.default.removeItem(at: zip) }
    if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
      throw UpdateError("下载失败（\(status)）")
    }
    let staging = try FileManager.default.url(
      for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
    defer { try? FileManager.default.removeItem(at: staging) }
    // 不要包里带的 ACL、扩展属性（签名在包内，用不着；也挡掉带进来的隔离标记）
    try await run(
      "/usr/bin/ditto", ["-x", "-k", "--noacl", "--noextattr", zip.path, staging.path],
      failure: "更新包解不开")
    guard
      let app = try FileManager.default.contentsOfDirectory(
        at: staging, includingPropertiesForKeys: nil
      ).first(where: { $0.pathExtension == "app" }),
      let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")),
      info["CFBundleIdentifier"] as? String == bundleID,
      info["CFBundleShortVersionString"] as? String == release.version
    else { throw UpdateError("更新包不对（App 或版本号对不上）") }
    // 文件权限不在签名里：去掉组 / 其他人的写权限和 setuid / setgid / sticky
    try await run("/bin/chmod", ["-R", "go-w,a-st", app.path], failure: "更新包的文件权限处理失败")
    try await run(
      "/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", requirement, app.path],
      failure: "更新包的签名校验没通过")
    _ = try FileManager.default.replaceItemAt(target, withItemAt: app)
  }

  /// 等本进程退出后重新打开
  private static func relaunch(_ app: URL) throws {
    let process = Process()
    process.executableURL = URL(filePath: "/bin/sh")
    process.arguments = [
      "-c",
      "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
      app.path,
    ]
    try process.run()
  }

  private static func run(_ tool: String, _ arguments: [String], failure: String) async throws {
    guard try await Subprocess.run(tool, arguments).status == 0 else { throw UpdateError(failure) }
  }
}

struct UpdateError: LocalizedError {
  let errorDescription: String?
  init(_ message: String) { errorDescription = message }
}
