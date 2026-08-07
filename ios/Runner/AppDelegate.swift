import Flutter
import UIKit
import Darwin

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var sourceTasks: [String: URLSessionDataTask] = [:]
  private var cancelledSourceTaskIDs = Set<String>()
  private let sourceTaskLock = NSLock()
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "LXFileProtection"
    ) else { return }
    let channel = FlutterMethodChannel(
      name: "lx_music/file_protection",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "ensureBackgroundReadable",
            let arguments = call.arguments as? [String: Any],
            let rawPath = arguments["path"] as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      let path = (rawPath as NSString).standardizingPath
      let home = (NSHomeDirectory() as NSString).standardizingPath + "/"
      guard path.hasPrefix(home), FileManager.default.fileExists(atPath: path) else {
        result(FlutterError(
          code: "invalid_path",
          message: "Playback cache path is outside the application container",
          details: nil
        ))
        return
      }
      do {
        try FileManager.default.setAttributes(
          [.protectionKey: FileProtectionType.none],
          ofItemAtPath: path
        )
        result(nil)
      } catch {
        result(FlutterError(
          code: "file_protection",
          message: error.localizedDescription,
          details: nil
        ))
      }
    }

    let sourceChannel = FlutterMethodChannel(
      name: "lx_music/source_transport",
      binaryMessenger: registrar.messenger()
    )
    sourceChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      if call.method == "cancel",
         let arguments = call.arguments as? [String: Any],
         let id = arguments["id"] as? String {
        self.sourceTaskLock.lock()
        let task = self.sourceTasks.removeValue(forKey: id)
        if task == nil {
          self.cancelledSourceTaskIDs.insert(id)
          DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            self?.sourceTaskLock.lock()
            self?.cancelledSourceTaskIDs.remove(id)
            self?.sourceTaskLock.unlock()
          }
        }
        self.sourceTaskLock.unlock()
        task?.cancel()
        result(nil)
        return
      }
      guard call.method == "request",
            let arguments = call.arguments as? [String: Any],
            let id = arguments["id"] as? String,
            let rawURL = arguments["url"] as? String,
            let url = URL(string: rawURL),
            url.scheme == "http" || url.scheme == "https" else {
        result(FlutterMethodNotImplemented)
        return
      }
      sourceTaskLock.lock()
      let wasCancelled = cancelledSourceTaskIDs.remove(id) != nil
      sourceTaskLock.unlock()
      if wasCancelled {
        result(FlutterError(code: "cancelled", message: "Source request was cancelled", details: nil))
        return
      }
      guard SourceTransportDelegate.hasOnlyPublicAddresses(host: url.host ?? "") else {
        result(FlutterError(code: "blocked_address", message: "Source destination is not public", details: nil))
        return
      }
      var request = URLRequest(url: url)
      request.httpMethod = arguments["method"] as? String ?? "GET"
      if let headers = arguments["headers"] as? [String: String] {
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
      }
      if let body = arguments["body"] as? String {
        request.httpBody = Data(base64Encoded: body)
      }
      let timeoutMs = arguments["timeoutMs"] as? Int ?? 15_000
      request.timeoutInterval = Double(timeoutMs) / 1_000.0

      let configuration = URLSessionConfiguration.ephemeral
      configuration.httpCookieAcceptPolicy = .never
      configuration.httpShouldSetCookies = false
      configuration.requestCachePolicy = .useProtocolCachePolicy
      let maximumResponseBytes = arguments["maximumResponseBytes"] as? Int ?? 10 * 1024 * 1024
      let delegate = SourceTransportDelegate(maximumResponseBytes: maximumResponseBytes) {
        [weak self] data, response, error in
        guard let self else { return }
        self.sourceTaskLock.lock()
        self.sourceTasks.removeValue(forKey: id)
        self.sourceTaskLock.unlock()
        DispatchQueue.main.async {
          if let error {
            result(FlutterError(code: "source_transport", message: error.localizedDescription, details: nil))
            return
          }
          guard let response = response as? HTTPURLResponse else {
            result(FlutterError(code: "source_transport", message: "Missing HTTP response", details: nil))
            return
          }
          var headers: [String: [String]] = [:]
          for (name, value) in response.allHeaderFields {
            headers[String(describing: name)] = [String(describing: value)]
          }
          result([
            "statusCode": response.statusCode,
            "statusMessage": HTTPURLResponse.localizedString(forStatusCode: response.statusCode),
            "headers": headers,
            "body": (data ?? Data()).base64EncodedString(),
          ])
        }
      }
      let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
      delegate.session = session
      let task = session.dataTask(with: request)
      sourceTaskLock.lock()
      if cancelledSourceTaskIDs.remove(id) != nil {
        sourceTaskLock.unlock()
        task.cancel()
        session.finishTasksAndInvalidate()
        result(FlutterError(code: "cancelled", message: "Source request was cancelled", details: nil))
        return
      }
      sourceTasks[id] = task
      sourceTaskLock.unlock()
      task.resume()
    }
  }
}

private final class SourceTransportDelegate: NSObject, URLSessionDataDelegate {
  weak var session: URLSession?
  private let maximumResponseBytes: Int
  private let completion: (Data?, URLResponse?, Error?) -> Void
  private var data = Data()
  private var response: URLResponse?
  private var completed = false

  init(
    maximumResponseBytes: Int,
    completion: @escaping (Data?, URLResponse?, Error?) -> Void
  ) {
    self.maximumResponseBytes = maximumResponseBytes
    self.completion = completion
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    if response.expectedContentLength > maximumResponseBytes {
      completionHandler(.cancel)
      finish(error: NSError(
        domain: "LXSourceTransport",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Source response exceeded the byte limit"]
      ))
      return
    }
    self.response = response
    completionHandler(.allow)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive data: Data
  ) {
    guard self.data.count + data.count <= maximumResponseBytes else {
      dataTask.cancel()
      finish(error: NSError(
        domain: "LXSourceTransport",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Source response exceeded the byte limit"]
      ))
      return
    }
    self.data.append(data)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    finish(error: error)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }

  private func finish(error: Error?) {
    guard !completed else { return }
    completed = true
    completion(error == nil ? data : nil, response, error)
    session?.finishTasksAndInvalidate()
  }

  static func hasOnlyPublicAddresses(host: String) -> Bool {
    guard !host.isEmpty else { return false }
    var hints = addrinfo(
      ai_flags: AI_ADDRCONFIG,
      ai_family: AF_UNSPEC,
      ai_socktype: SOCK_STREAM,
      ai_protocol: IPPROTO_TCP,
      ai_addrlen: 0,
      ai_canonname: nil,
      ai_addr: nil,
      ai_next: nil
    )
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
      return false
    }
    defer { freeaddrinfo(result) }
    var current: UnsafeMutablePointer<addrinfo>? = first
    var found = false
    while let info = current {
      guard let address = info.pointee.ai_addr else { return false }
      found = true
      if address.pointee.sa_family == sa_family_t(AF_INET) {
        let value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
          UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
        }
        let first = UInt8((value >> 24) & 0xff)
        let second = UInt8((value >> 16) & 0xff)
        if first == 0 || first == 10 || first == 127 || first >= 224 ||
           (first == 100 && second >= 64 && second <= 127) ||
           (first == 169 && second == 254) ||
           (first == 172 && second >= 16 && second <= 31) ||
           (first == 192 && second == 168) {
          return false
        }
      } else if address.pointee.sa_family == sa_family_t(AF_INET6) {
        let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
          withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) }
        }
        if bytes.allSatisfy({ $0 == 0 }) || bytes == Array(repeating: 0, count: 15) + [1] ||
           (bytes[0] & 0xfe) == 0xfc ||
           (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) || bytes[0] == 0xff {
          return false
        }
      }
      current = info.pointee.ai_next
    }
    return found
  }
}
