import Flutter
import Foundation
import UIKit
import os

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
  /// Breeze-ASR-26 q8_0 (Taiwanese speech -> Mandarin characters), loaded on the
  /// first Taiwanese clip (docs/AI_TAIWANESE_SPEECH_PLAN.md), as on Android.
  static let taiwaneseAsrFile = "ggml-whisper-taiwanese.bin"

  private static let modelPort = 8771
  private static let multiWhisperPort = 8773
  private static let faqEmbedPort = 8774
  private static let gateWhisperPort = 8775
  private static let taiwaneseWhisperPort = 8776

  private let lock = NSLock()
  private var state: String?

  // Set by launch(); startTaiwanese() starts the Taiwanese server with them.
  private var modelsDirectory: URL?
  private var whisperLibrary: String?
  private var whisperThreads = "4"
  private let taiwaneseLock = NSLock()
  private var taiwaneseStarted = false
  /// Signalled when every start-up server has loaded (or given up): the
  /// Taiwanese model never loads while another model is still loading.
  private let startupDone = DispatchSemaphore(value: 0)

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

    let cpu = ProcessInfo.processInfo.activeProcessorCount
    let threads = String(max(2, min(4, cpu - 2)))
    modelsDirectory = models
    whisperLibrary = "\(frameworks)/WhisperServer.framework/WhisperServer"
    whisperThreads = threads

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
        // Always offered with Whisper: the file is looked for on first use
        // (startTaiwanese); without it Taiwanese clips are heard as Chinese, with a notice.
        "taiwanese_port=\(multilingual ? String(Self.taiwaneseWhisperPort) : "None")",
        "taiwanese_starter=device_main.native_starter(\(UInt(bitPattern: unsafeBitCast(taiwaneseStarter, to: Int.self))))",
        "decision_model='ministral'",
      ])
    if let pythonInfo { return "failed: \(pythonInfo)" }

    // iPhone 15-17: 2 performance + 4 efficiency cores; the GPU (Metal) does
    // most of the work, so a few CPU threads (threads, above) are enough.
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
        // Ready = model loaded. whisper-server listens only after loading, but
        // llama-server listens at once and answers /health with 503 until its model
        // is loaded; starting the next model before that overlapped their GPU set-up
        // and the App crashed (2026-11-08).
        let llama = server.symbol == "townpass_llama_server"
        func ready() -> Bool { llama ? healthy(server.port) : listening(server.port) }
        while !ready() && Date().timeIntervalSince(began) < 180 {
          Thread.sleep(forTimeInterval: 0.25)
        }
        note(
          String(
            format: "%@ %@ after %.1f s; %@", server.name,
            ready() ? "ready" : "not ready", Date().timeIntervalSince(began), memoryNote()))
      }
      startupDone.signal()
    }
    starter.name = "assistant-start"
    starter.start()
    return "started python :8765; loading " + plan.map { "\($0.name) :\($0.port)" }
      .joined(separator: ", ") + (multilingual ? "" : "; no whisper model")
  }

  private func availableMB() -> Int { Int(os_proc_available_memory() >> 20) }

  /// Physical memory the phone could give right now: free, inactive, speculative
  /// and purgeable pages (wired GPU buffers and other apps' active pages are not).
  private func reclaimableMemory() -> UInt64 {
    var info = vm_statistics64()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
      }
    }
    guard status == KERN_SUCCESS else { return 0 }
    let pages =
      UInt64(info.free_count) + UInt64(info.inactive_count) + UInt64(info.speculative_count)
      + UInt64(info.purgeable_count)
    return pages * UInt64(vm_kernel_page_size)
  }

  private func memoryNote() -> String {
    "\(availableMB()) MB app budget, \(reclaimableMemory() >> 20) MB phone free, "
      + "\(ProcessInfo.processInfo.physicalMemory >> 20) MB RAM"
  }

  /// Whether llama-server on 127.0.0.1:[port] has loaded its model (GET /health is 200).
  private func healthy(_ port: Int) -> Bool {
    let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard socket >= 0 else { return false }
    defer { close(socket) }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port).bigEndian)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
      }
    }
    guard connected else { return false }
    let request = "GET /health HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n"
    guard request.withCString({ send(socket, $0, strlen($0), 0) }) > 0 else { return false }
    var buffer = [UInt8](repeating: 0, count: 64)
    let count = recv(socket, &buffer, buffer.count, 0)
    guard count > 12 else { return false }
    // "HTTP/1.1 200 OK"
    return String(decoding: buffer[9..<12], as: UTF8.self) == "200"
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

  /// Starts the Taiwanese whisper-server if it is not running yet and waits until
  /// it has loaded (called by the backend through device_main.native_starter, on a
  /// backend thread, only for clips that may be Taiwanese). Returns "ready",
  /// "missing" (file not pushed), "memory" (not enough free memory; nothing else
  /// is stopped) or "failed", like Android's OnDeviceAssistant.startTaiwanese.
  func startTaiwanese() -> String {
    taiwaneseLock.lock()
    defer { taiwaneseLock.unlock() }
    guard let models = modelsDirectory, let whisper = whisperLibrary else { return "failed" }
    if listening(Self.taiwaneseWhisperPort) { return "ready" }
    // Not while the start-up models are still loading (one load at a time).
    if startupDone.wait(timeout: .now() + 300) == .success { startupDone.signal() }
    let model = models.appendingPathComponent(Self.taiwaneseAsrFile)
    guard
      let size = (try? FileManager.default.attributesOfItem(atPath: model.path))?[.size] as? UInt64
    else { return "missing" }
    let began = Date()
    if !taiwaneseStarted {
      // On the GPU it takes its weights (the file) plus ~600 MB of large-model caches
      // and compute buffers (kv cross 1500 x 32 layers, decode). Android's CPU figure
      // (1.28x the file) over-counted and refused a 12 GB iPhone with 2.8 GB free.
      // Both limits must allow it: the App's own budget (os_proc_available_memory)
      // and the phone's free physical memory. Model weights on the GPU are wired
      // memory that the App's budget does not count: on an 8 GB iPhone 17 the
      // budget said 4.5 GB free while the phone had 54 MB left, and iOS killed the
      // App for page shortage (vm-pageshortage) as Breeze loaded (2026-11-08).
      let needed = size + 600 * 1024 * 1024
      let budget = UInt64(os_proc_available_memory())
      let physical = reclaimableMemory()
      let reserve: UInt64 = 400 * 1024 * 1024  // iOS and its services
      note(
        "taiwanese speech: needs \(needed >> 20) MB; app budget \(budget >> 20) MB, "
          + "phone free \(physical >> 20) MB (keeps \(reserve >> 20) MB)")
      if budget < needed || physical < needed + reserve {
        return "memory"
      }
      guard
        runServer(
          library: whisper, symbol: "townpass_whisper_server", name: "whisper-taiwanese",
          arguments: serverArguments(models, Self.taiwaneseAsrFile, Self.taiwaneseWhisperPort)
            + ["-t", whisperThreads, "-l", "zh"], restart: true)
      else { return "failed" }
      taiwaneseStarted = true
    }
    // whisper-server listens only after the model has loaded.
    while Date().timeIntervalSince(began) < 60 {
      if listening(Self.taiwaneseWhisperPort) {
        note(String(format: "taiwanese speech loaded in %.1f s", Date().timeIntervalSince(began)))
        return "ready"
      }
      Thread.sleep(forTimeInterval: 0.2)
    }
    return "failed"
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
    // When iOS reclaims a suspended App's listening socket, llama-server and
    // whisper-server bind the same port again by themselves, keeping the model
    // loaded (ios/native/llama-server-rebind.patch, whisper-server-ios.patch).
    // Unpatched whisper-server returned from main() instead and reloaded its model
    // on every resume (Breeze: 1.6 GB); if a server still exits, it is run again
    // once the App is active. Quick repeated exits stop after five tries.
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

/// The C function the backend calls to start the Taiwanese server
/// (device_main.native_starter). ctypes copies the returned text; the few bytes
/// of each strdup are not freed (one call per Taiwanese clip at most).
private let taiwaneseStarter: @convention(c) () -> UnsafeMutablePointer<CChar>? = {
  strdup(OnDeviceAssistant.shared.startTaiwanese())
}
