import Flutter
import Foundation
import UIKit

/// Runs the local service assistant inside the iOS App (docs/AI_ON_DEVICE_IOS.md),
/// the iOS twin of android/.../OnDeviceAssistant.kt. Same loopback endpoints, so
/// the Flutter side and the HTTP contract do not change:
///
///  - llama.cpp llama-server (Ministral 3B GGUF)              127.0.0.1:8771
///  - whisper.cpp whisper-server (Whisper small, multilingual) 127.0.0.1:8773
///  - whisper-server (Whisper tiny, language detection only)   127.0.0.1:8775, optional
///  - llama-server --embedding (multilingual-e5-small)         127.0.0.1:8774, optional
///  - Python backend (device_main.py, embedded CPython 3.13)   127.0.0.1:8765 and :8770
///
/// iOS cannot start child processes, so each native server's main() runs on its
/// own thread in the App process. The frameworks (LlamaServer, WhisperServer,
/// Python) are not linked: ios/scripts/embed_on_device_assistant.sh copies them in
/// when ios/OnDevice/ holds them, and they are opened here with dlopen, so builds
/// without them are unchanged. Model files are not in the App:
/// scripts/push_assistant_models_ios.sh copies them to Documents/models.
///
/// Started from Dart (lib/service/assistant_on_device.dart) only in builds made
/// with --dart-define=ASSISTANT_ON_DEVICE=true.
final class OnDeviceAssistant {
  static let shared = OnDeviceAssistant()

  static let modelFile = "Ministral-3-3B-Instruct-2512-Q4_K_M.gguf"
  static let multiAsrFile = "ggml-whisper-multilingual.bin"
  static let gateAsrFile = "ggml-whisper-langid.bin"
  static let faqModelFile = "multilingual-e5-small-q8_0.gguf"
  static let faqIndexDir = "faq_rag"

  private static let modelPort = 8771
  private static let multiWhisperPort = 8773
  private static let faqEmbedPort = 8774
  private static let gateWhisperPort = 8775

  private let lock = NSLock()
  private var state: String?

  private typealias ServerMain = @convention(c) (
    Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
  ) -> Int32

  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "townpass/on_device_assistant", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      switch call.method {
      case "start":
        DispatchQueue.global(qos: .userInitiated).async {
          let info = self.start()
          DispatchQueue.main.async { result(info) }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Starts everything once; returns what was started (or why not), numbers and
  /// file names only. The models load behind the listening Python servers:
  /// requests get the usual "not ready yet" replies until they answer.
  func start() -> String {
    lock.lock()
    defer { lock.unlock() }
    if let state { return state }
    let info = launch()
    state = info
    note(info)
    return info
  }

  private func launch() -> String {
    let fileManager = FileManager.default
    guard
      let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first,
      let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
      let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first,
      let frameworks = Bundle.main.privateFrameworksPath,
      let resources = Bundle.main.resourcePath
    else { return "failed: no app folders" }
    let models = documents.appendingPathComponent("models")
    try? fileManager.createDirectory(at: models, withIntermediateDirectories: true)
    try? fileManager.createDirectory(at: support, withIntermediateDirectories: true)
    func has(_ name: String) -> Bool { fileManager.fileExists(atPath: models.appendingPathComponent(name).path) }

    let python = "\(frameworks)/Python.framework/Python"
    let backend = "\(resources)/assistant_backend"
    guard fileManager.fileExists(atPath: python), fileManager.fileExists(atPath: backend) else {
      return "not embedded: build with ios/OnDevice/ (scripts/setup_ios_on_device.sh)"
    }
    guard has(Self.modelFile) else {
      return "missing \(Self.modelFile): run scripts/push_assistant_models_ios.sh"
    }

    // Everything the servers and Python print goes to one log the Mac can copy
    // back (Library/Caches/on_device_assistant.log, this launch only); release iOS shows no stdout.
    let log = caches.appendingPathComponent("on_device_assistant.log").path
    if freopen(log, "w", stdout) != nil { setvbuf(stdout, nil, _IOLBF, 0) }
    if freopen(log, "a", stderr) != nil { setvbuf(stderr, nil, _IONBF, 0) }

    let multilingual = has(Self.multiAsrFile)
    let gate = multilingual && has(Self.gateAsrFile)
    let faqIndex = models.appendingPathComponent(Self.faqIndexDir)
    let faq =
      has(Self.faqModelFile)
      && fileManager.fileExists(atPath: faqIndex.appendingPathComponent("embeddings.bin").path)

    // Python first: it listens at once; the native servers load behind it.
    let pythonInfo = startPython(
      library: python, home: "\(resources)/python", backend: backend, support: support.path,
      arguments: [
        "model_port=\(Self.modelPort)",
        "whisper_port=\(Self.multiWhisperPort)",
        "whisper=True",
        "multi_port=\(multilingual ? String(Self.multiWhisperPort) : "None")",
        "chinese_model=\(multilingual ? "False" : "True")",
        "gate_port=\(gate ? String(Self.gateWhisperPort) : "None")",
        "faq_port=\(faq ? String(Self.faqEmbedPort) : "None")",
        "faq_dir=\(faq ? pythonString(faqIndex.path) : "None")",
        // No Taiwanese model on iOS yet: Taiwanese clips are heard as Chinese, with a notice.
        "taiwanese_port=None",
        "decision_model='ministral'",
      ])
    if let pythonInfo { return "failed: \(pythonInfo)" }

    // iPhone 15-17 Pro: 2 performance + 4 efficiency cores; the GPU (Metal) does
    // most of the work, so a few CPU threads are enough.
    let cpu = ProcessInfo.processInfo.activeProcessorCount
    let threads = String(max(2, min(4, cpu - 2)))
    let llama = "\(frameworks)/LlamaServer.framework/LlamaServer"
    let whisper = "\(frameworks)/WhisperServer.framework/WhisperServer"
    // One server at a time, each started after the previous one listens: started
    // together, their Metal shader compiles overlapped, the system's shader
    // compiler connection dropped (XPC_ERROR_CONNECTION_INTERRUPTED) and
    // whisper.cpp aborted on a half-made GPU context. The decision model first.
    var plan: [(name: String, library: String, symbol: String, port: Int, arguments: [String])] = [
      // Same settings as Android: one 2048-token slot per decision policy kept in
      // the prompt cache, no host-RAM prompt cache, no thinking block.
      ("llama-decision", llama, "townpass_llama_server", Self.modelPort,
       serverArguments(models, Self.modelFile, Self.modelPort)
         + ["-t", threads, "-c", "6144", "-np", "3", "--cache-ram", "0",
            "--reasoning", "off", "--no-webui"])
    ]
    if multilingual {
      plan.append(
        ("whisper-multilingual", whisper, "townpass_whisper_server", Self.multiWhisperPort,
         serverArguments(models, Self.multiAsrFile, Self.multiWhisperPort)
           + ["-t", threads, "-l", "auto"]))
    }
    if gate {
      // Detection only (encoder + one step): on the CPU (-ng), ~0.2 s a clip,
      // and one GPU context fewer.
      plan.append(
        ("whisper-langid", whisper, "townpass_whisper_server", Self.gateWhisperPort,
         serverArguments(models, Self.gateAsrFile, Self.gateWhisperPort)
           + ["-t", threads, "-l", "auto", "-ng"]))
    }
    if faq {
      plan.append(
        ("llama-embedding", llama, "townpass_llama_server", Self.faqEmbedPort,
         serverArguments(models, Self.faqModelFile, Self.faqEmbedPort)
           + ["--embedding", "--pooling", "mean", "-c", "512", "-b", "512", "-ub", "512",
              "-np", "1", "-t", "2", "--no-webui"]))
    }
    let starter = Thread { [self] in
      for server in plan {
        let began = Date()
        guard
          runServer(
            library: server.library, symbol: server.symbol, name: server.name,
            arguments: server.arguments, restart: server.symbol == "townpass_whisper_server")
        else { continue }
        // Servers listen only after their model has loaded.
        while !listening(server.port) && Date().timeIntervalSince(began) < 180 {
          Thread.sleep(forTimeInterval: 0.25)
        }
        note(
          String(
            format: "%@ %@ after %.1f s", server.name,
            listening(server.port) ? "listening" : "not listening", Date().timeIntervalSince(began)))
      }
    }
    starter.name = "assistant-start"
    starter.start()
    return "started python :8765; loading " + plan.map { "\($0.name) :\($0.port)" }
      .joined(separator: ", ") + (multilingual ? "" : "; no whisper model")
  }

  private func appIsActive() -> Bool {
    DispatchQueue.main.sync { UIApplication.shared.applicationState == .active }
  }

  /// Whether something accepts connections on 127.0.0.1:[port].
  private func listening(_ port: Int) -> Bool {
    let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard socket >= 0 else { return false }
    defer { close(socket) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port).bigEndian)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    return withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
      }
    }
  }

  /// To the system log and to on_device_assistant.log (stderr, once redirected).
  private func note(_ text: String) {
    NSLog("TownPassAssistant: %@", text)
    fputs("TownPassAssistant: \(text)\n", stderr)
  }

  private func serverArguments(_ models: URL, _ file: String, _ port: Int) -> [String] {
    ["-m", models.appendingPathComponent(file).path, "--host", "127.0.0.1", "--port", String(port)]
  }

  /// Runs a native server's main() on its own thread; false when it could not be opened.
  private func runServer(
    library: String, symbol: String, name: String, arguments: [String], restart: Bool
  ) -> Bool {
    guard let handle = dlopen(library, RTLD_NOW | RTLD_LOCAL),
      let address = dlsym(handle, symbol)
    else {
      note("cannot open \(name) (\(String(cString: dlerror())))")
      return false
    }
    let main = unsafeBitCast(address, to: ServerMain.self)
    let argv = ([name] + arguments).map { strdup($0) }
    // whisper-server returns from main() when iOS reclaims its listening socket
    // while the App is suspended (phone locked); it is run again once the App is
    // active. llama-server binds the same port again by itself (patched,
    // ios/native/llama-server-rebind.patch). Quick repeated exits (a broken
    // model or port) stop after five tries.
    let thread = Thread { [self] in
      var quickExits = 0
      while true {
        let began = Date()
        var pointers: [UnsafeMutablePointer<CChar>?] = argv + [nil]
        let code = main(Int32(argv.count), &pointers)
        note("\(name) exited with \(code)")
        guard restart else { return }
        quickExits = Date().timeIntervalSince(began) < 10 ? quickExits + 1 : 0
        if quickExits >= 5 {
          note("\(name) keeps exiting; not restarted")
          return
        }
        while !appIsActive() { Thread.sleep(forTimeInterval: 1) }
        Thread.sleep(forTimeInterval: 1)
        note("\(name) restarting")
      }
    }
    thread.name = name
    // llama-server and whisper-server use deep stacks while loading models.
    thread.stackSize = 16 << 20
    thread.qualityOfService = .userInitiated
    thread.start()
    return true
  }

  private typealias PyInitializeEx = @convention(c) (Int32) -> Void
  private typealias PyRunSimpleString = @convention(c) (UnsafePointer<CChar>) -> Int32
  private typealias PyEvalSaveThread = @convention(c) () -> OpaquePointer?

  /// Starts CPython with the App's copy of the standard library and
  /// assistant_backend, then device_main.start(...). Returns an error text, or nil.
  private func startPython(
    library: String, home: String, backend: String, support: String, arguments: [String]
  ) -> String? {
    guard let handle = dlopen(library, RTLD_NOW | RTLD_GLOBAL) else {
      return "cannot open Python (\(String(cString: dlerror())))"
    }
    guard let initialize = dlsym(handle, "Py_InitializeEx"),
      let run = dlsym(handle, "PyRun_SimpleString"),
      let save = dlsym(handle, "PyEval_SaveThread")
    else { return "Python symbols missing" }
    let version = (try? FileManager.default.contentsOfDirectory(atPath: "\(home)/lib"))?
      .first { $0.hasPrefix("python3.") } ?? "python3.13"
    setenv("PYTHONHOME", home, 1)
    setenv("PYTHONPATH", "\(backend):\(home)/lib/\(version)", 1)
    setenv("PYTHONDONTWRITEBYTECODE", "1", 1)  // the App bundle is read-only
    setenv("PYTHONUNBUFFERED", "1", 1)
    setenv("PYTHONUTF8", "1", 1)
    setenv("NO_COLOR", "1", 1)
    // Apple's root certificates, bundled by embed_on_device_assistant.sh.
    setenv("SSL_CERT_FILE", "\(home)/cacert.pem", 1)
    // faq.py / semantic.py / qna.py keep their caches under LOCALAPPDATA/TownPassAssistant.
    setenv("LOCALAPPDATA", support, 1)
    // 0: no Python signal handlers; the native servers own SIGINT/SIGTERM.
    unsafeBitCast(initialize, to: PyInitializeEx.self)(0)
    let code = """
      import os, sys
      # Python on iOS may send print() to the system log; keep it in
      # on_device_assistant.log with the servers' output (fd 1/2, redirected above).
      sys.stdout = open(1, "w", buffering=1, encoding="utf-8", errors="replace", closefd=False)
      sys.stderr = open(2, "w", buffering=1, encoding="utf-8", errors="replace", closefd=False)
      import device_main
      print("backend:", device_main.start(\(arguments.joined(separator: ", "))), flush=True)
      """
    let status = code.withCString { unsafeBitCast(run, to: PyRunSimpleString.self)($0) }
    // Let the backend's own threads run: this thread keeps no hold on the GIL.
    _ = unsafeBitCast(save, to: PyEvalSaveThread.self)()
    return status == 0 ? nil : "device_main.start failed (see on_device_assistant.log)"
  }

  private func pythonString(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
      + "'"
  }
}
