import Flutter
import Foundation
import UIKit
import os

/// Runs the local service assistant inside the iOS App (portal_assistant/docs/AI_ON_DEVICE_IOS.md),
/// the iOS twin of android/.../OnDeviceAssistant.kt. Same loopback endpoints, so
/// the Flutter side and the HTTP contract do not change:
///
///  - llama.cpp llama-server (Ministral 3B GGUF)              127.0.0.1:8771
///  - whisper.cpp whisper-server (Whisper small, multilingual) 127.0.0.1:8773
///  - whisper-server (Whisper tiny, language detection only)   127.0.0.1:8775, optional
///  - llama-server --embedding (multilingual-e5-small)         127.0.0.1:8774, optional
///  - llama-server --reranking (decision classifier)           127.0.0.1:8778, instead of
///    the decision model in builds with ASSISTANT_DECISION_MODEL=classifier (option B')
///  - Python backend (device_main.py, embedded CPython 3.13)   127.0.0.1:8765 and :8770
///
/// iOS cannot start child processes, so each native server's main() runs on its
/// own thread in the App process. The frameworks (LlamaServer, WhisperServer,
/// Python) are not linked: portal_assistant/native/ios/embed_on_device_assistant.sh copies them in
/// when ios/OnDevice/ holds them, and they are opened here with dlopen, so builds
/// without them are unchanged. Model files are not in the App:
/// portal_assistant/scripts/push_assistant_models_ios.sh copies them to Documents/models.
///
/// Started from Dart (portal_assistant/app/lib/service/assistant_on_device.dart) only in builds made
/// with --dart-define=ASSISTANT_ON_DEVICE=true.
final class OnDeviceAssistant {
  static let shared = OnDeviceAssistant()

  static let modelFile = "Ministral-3-3B-Instruct-2512-Q4_K_M.gguf"
  static let multiAsrFile = "ggml-whisper-multilingual.bin"
  static let gateAsrFile = "ggml-whisper-langid.bin"
  static let faqModelFile = "multilingual-e5-small-q8_0.gguf"
  static let faqIndexDir = "faq_rag"
  /// Breeze-ASR-26 q8_0 (Taiwanese speech -> Mandarin characters), loaded on the
  /// first Taiwanese clip (portal_assistant/docs/AI_TAIWANESE_SPEECH_PLAN.md), as on Android.
  static let taiwaneseAsrFile = "ggml-whisper-taiwanese.bin"
  /// Option B' (portal_assistant/docs/AI_DECISION_CLASSIFIER.md section 12, opt-in with
  /// --dart-define=ASSISTANT_DECISION_MODEL=classifier): no decision model at all; this
  /// cross-encoder (fine-tuned from Microsoft multilingual-e5-small, MIT, 132 MB) scores
  /// the candidate pages. Same file and port as Android's OnDeviceAssistant.kt.
  static let classifierModelFile = "townpass-decision-e5-ce-v2-q8_0.gguf"

  private static let assistantPort = 8765
  private static let asrPort = 8770
  private static let modelPort = 8771
  private static let multiWhisperPort = 8773
  private static let faqEmbedPort = 8774
  private static let gateWhisperPort = 8775
  private static let taiwaneseWhisperPort = 8776
  private static let classifierPort = 8778  // device_main.PORTS["classifier"]
  private static let taiwaneseName = "whisper-taiwanese"
  /// Breeze-ASR-26 (Whisper large) besides its file, and what must stay free after it
  /// (startTaiwanese, memoryAllows). 2026-11-16: 750 MB, was 1,000. whisper.cpp printed on
  /// the iPhone (q4_0, Metal): weights 888 + KV 343 + compute 335 = 1,567 MB (10^6 bytes),
  /// i.e. 646 MiB besides the 848 MiB file, all allocated at load; the App's budget fell by
  /// 1,327 MB after loading and one clip. The 1,000 also covered whisper.cpp re-creating its
  /// self-attention KV cache at 4x (+240 MiB) on the first temperature fallback with
  /// best_of 2; the server now runs with -bo 1 and the backend asks best_of 1, so that
  /// never happens (portal_assistant/docs/AI_TAIWANESE_ABLATION.md section 14). q8_0 under this rule needs
  /// 1,579 + 750 + 256 MB: the 2,247 MB budget that aborted on 2026-11-13 is refused.
  private static let taiwaneseOverhead: UInt64 = 750 << 20
  private static let taiwaneseMargin: UInt64 = 256 << 20

  private let lock = NSLock()
  private var state: String?

  /// A native server this launch started: what status() checks and what recover()
  /// runs again when its thread gave up while the App was away.
  private struct Server {
    let name: String
    let library: String
    let symbol: String
    let port: Int
    let arguments: [String]
    /// Its model file in Documents/models.
    var file: String? = nil
    var llama: Bool { symbol == "townpass_llama_server" }
  }
  private let serversLock = NSLock()
  /// Every server started so far, in start order.
  private var servers: [Server] = []
  /// The start-up servers by ensureServer name, also those whose file is not here yet.
  private var planned: [String: Server] = [:]
  /// One model load at a time (overlapping Metal set-ups crashed the App, 2026-11-08).
  private let loadLock = NSLock()
  /// Names of servers whose thread gave up (it kept exiting); recover() runs them again.
  private var stopped: Set<String> = []
  private let recoverLock = NSLock()

  // Set by launch(); startTaiwanese() starts the Taiwanese server with them.
  private var modelsDirectory: URL?
  private var whisperLibrary: String?
  private var whisperThreads = "4"
  private let taiwaneseLock = NSLock()
  private var taiwaneseStarted = false
  /// Signalled when every start-up server has loaded (or given up): the
  /// Taiwanese model never loads while another model is still loading.
  private let startupDone = DispatchSemaphore(value: 0)
  /// Whether the App is active: only from didBecomeActive until willResignActive
  /// (2026-11-18; it used to turn true at willEnterForeground, before iOS allows GPU work,
  /// and stayed true while the App was resigning). iOS refuses GPU work from the
  /// background, and a failed Metal command buffer leaves ggml's Metal backend broken until
  /// that server restarts; the backend asks before each speech pass (appActiveFlag,
  /// device_main.native_flag), and the whisper-servers stop a clip in progress at its next
  /// step while it is false (whisperPause).
  private let activeLock = NSLock()
  private var activeNow = true
  /// townpass_whisper_server_pause(paused) (whisper-server-ios.patch, 2026-11-18): one flag
  /// for every whisper-server in the App, set with activeNow (under activeLock). Found by
  /// runServer once WhisperServer is open; older frameworks do not have it.
  private typealias WhisperPause = @convention(c) (Int32) -> Void
  private var whisperPause: WhisperPause?
  /// townpass_whisper_server_busy(port): clips in progress, -1 when no server runs there.
  private typealias WhisperBusy = @convention(c) (Int32) -> Int32
  /// townpass_whisper_server_fixes(): 1 when the 2026-11-18 free fix is built in.
  private typealias WhisperFixes = @convention(c) () -> Int32
  /// Servers that failed and are not restarted inside the App (restart): speech then asks
  /// for the App to be opened again instead of freeing a model in the App (under serversLock).
  private var relaunch: Set<String> = []
  /// The lifecycle record, Library/Caches/on_device_assistant.state (2026-11-18): rewritten at
  /// each change so that the next launch can tell how this one ended. Set by launch().
  private let stateLock = NSLock()
  private var stateURL: URL?
  private var phase = "active"
  private var restartingName = ""
  /// WhisperServer's size and date: which native build a crash during a restart belongs to.
  private var whisperBuild = ""
  /// A launch of this WhisperServer build ended while a whisper-server was being restarted
  /// (probably a crash while it freed its model): no more in-App restarts with this build.
  private var restartUnsafe = false
  /// townpass_whisper_server_stop(port) (portal_assistant/native/ios/whisper-server-ios.patch, frameworks
  /// built from 2026-11-13): stops one whisper-server, whose main() then frees its model
  /// and returns; runServer's loop runs it again. Older frameworks do not have it.
  private typealias WhisperStop = @convention(c) (Int32) -> Int32

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
        // The build's ASSISTANT_DECISION_MODEL, sent by portal_assistant/app/lib/service/assistant_on_device.dart.
        let arguments = call.arguments as? [String: Any]
        let decisionModel = arguments?["decision_model"] as? String ?? "classifier"
        DispatchQueue.global(qos: .userInitiated).async {
          let info = self.start(decisionModel: decisionModel)
          DispatchQueue.main.async { result(info) }
        }
      case "status":
        DispatchQueue.global(qos: .userInitiated).async {
          let info = self.status()
          DispatchQueue.main.async { result(info) }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    // The App's state, from both the UIApplication and the UIScene notifications (the App
    // uses the UIScene lifecycle). Active only at didBecomeActive / didActivate (2026-11-18:
    // willEnterForeground comes before iOS allows GPU work again); inactive already at
    // willResignActive / willDeactivate, so no new GPU work starts while the App leaves.
    // Back active (phone unlocked, back from another App): recover() runs again any server
    // that stopped while the App was away; it runs once at a time and does nothing when
    // every server is running.
    let events: [(Notification.Name, String, String)] = [
      (UIApplication.didBecomeActiveNotification, "didBecomeActive", "active"),
      (UIScene.didActivateNotification, "scene didActivate", "active"),
      (UIApplication.willResignActiveNotification, "willResignActive", "inactive"),
      (UIScene.willDeactivateNotification, "scene willDeactivate", "inactive"),
      (UIApplication.didEnterBackgroundNotification, "didEnterBackground", "background"),
      (UIScene.didEnterBackgroundNotification, "scene didEnterBackground", "background"),
      (UIApplication.willEnterForegroundNotification, "willEnterForeground", "inactive"),
      (UIScene.willEnterForegroundNotification, "scene willEnterForeground", "inactive"),
    ]
    for (name, label, next) in events {
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
        self?.lifecycle(label, to: next)
      }
    }
    NotificationCenter.default.addObserver(
      forName: UIApplication.willTerminateNotification, object: nil, queue: nil
    ) { [weak self] _ in
      self?.recordEnd()
    }
  }

  /// One App state change: active or not (activeNow and the whisper-servers' pause flag),
  /// one log line and the lifecycle record once launch() has run.
  private func lifecycle(_ label: String, to next: String) {
    let active = next == "active"
    setActive(active)
    if recordPhase(next) {
      note("lifecycle: \(label) -> \(next)")
    }
    if active {
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.recover() }
    }
  }

  /// Whether the App is in the foreground (kept by the notifications above, so the
  /// backend's threads never wait for the main thread to ask UIKit).
  func isActive() -> Bool {
    activeLock.lock()
    defer { activeLock.unlock() }
    return activeNow
  }

  private func setActive(_ value: Bool) {
    activeLock.lock()
    activeNow = value
    // A clip in progress stops at its next step while the App is not active (503); the
    // backend asks again once it is active.
    whisperPause?(value ? 0 : 1)
    activeLock.unlock()
  }

  /// Rewrites the lifecycle record (stateLock held). Numbers and server names only.
  private func writeState(ended: Bool = false) {
    guard let url = stateURL else { return }
    let text = "phase=\(phase)\nended=\(ended ? 1 : 0)\nrestarting=\(restartingName)\n"
      + "whisper=\(whisperBuild)\ntime=\(Int(Date().timeIntervalSince1970))\n"
    try? text.write(to: url, atomically: true, encoding: .utf8)
  }

  /// false before launch() (nothing is recorded then).
  private func recordPhase(_ value: String) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard stateURL != nil else { return false }
    phase = value
    writeState()
    return true
  }

  /// The whisper-server being restarted (freeing and loading its model), or nil when done.
  private func recordRestart(_ name: String?) {
    stateLock.lock()
    restartingName = name ?? ""
    writeState()
    stateLock.unlock()
  }

  private func recordEnd() {
    stateLock.lock()
    writeState(ended: true)
    stateLock.unlock()
  }

  /// How the previous launch ended, from the record it kept (launch()), the whisper-server
  /// it was restarting then ("" for none) and its WhisperServer build.
  private func previousLaunch(_ url: URL) -> (summary: String, restarting: String, build: String) {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
      return ("no record (first launch that keeps one, or it was cleared)", "", "")
    }
    var fields: [String: String] = [:]
    for line in text.split(separator: "\n") {
      let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
    }
    let lastPhase = fields["phase"] ?? "unknown"
    let restarting = fields["restarting"] ?? ""
    var ago = ""
    if let time = Double(fields["time"] ?? "") {
      ago = String(format: "; last record %.0f s before this launch", Date().timeIntervalSince1970 - time)
    }
    let summary: String
    if fields["ended"] == "1" {
      summary = "ended normally (the App was closed)"
    } else if !restarting.isEmpty {
      summary = "ended while \(restarting) was restarting (\(lastPhase)): probably a crash in the restart"
    } else if lastPhase == "background" {
      summary = "ended in the background (iOS closed the suspended App, or it was swiped away)"
    } else {
      summary = "ended in the foreground (\(lastPhase)) without closing: probably a crash or a stop by iOS "
        + "(look for Runner-*.ips or JetsamEvent-*.ips)"
    }
    return (summary + ago, restarting, fields["whisper"] ?? "")
  }

  /// Which servers answer now ("status" from Dart, which waits for ready after the
  /// App comes back: portal_assistant/app/lib/service/assistant_on_device.dart). ready: Python's two
  /// listeners and every start-up server answer; the Taiwanese server (first use
  /// only) is listed but not required. Nothing launched (not started yet, no
  /// model files) is ready too: there is nothing to wait for.
  func status() -> [String: Any] {
    lock.lock()
    let started = state != nil
    lock.unlock()
    serversLock.lock()
    let list = servers
    let waitingForRelaunch = relaunch
    serversLock.unlock()
    let python = listening(Self.assistantPort) && listening(Self.asrPort)
    var answering: [String: Bool] = [:]
    for server in list {
      // GET /health (llama-server and whisper-server both have it), not only a
      // connect: a server must also answer.
      answering[server.name] = healthy(server.port)
    }
    // A server marked for an App relaunch (restart) is not waited for: it stays down
    // until the App is opened again, and the backend says so for each clip.
    let ready = !started || list.isEmpty
      || (python && list.allSatisfy {
        $0.name == Self.taiwaneseName || waitingForRelaunch.contains($0.name) || answering[$0.name] == true
      })
    return ["started": started, "python": python, "servers": answering, "ready": ready,
            "relaunch": waitingForRelaunch.sorted()]
  }

  /// After the App comes back to the foreground: a server whose thread gave up (it
  /// kept exiting, e.g. while iOS had the App suspended) is run again, then every
  /// started server is asked GET /health and one that does not answer is restarted
  /// (restart; 2026-11-13: after unlocking, servers whose socket iOS had reclaimed
  /// stayed silent and turns waited for minutes), then which servers answer is logged.
  /// Servers that only exited once restart by themselves (runServer); Python re-opens
  /// its own listeners (device_main.watch).
  private func recover() {
    guard recoverLock.try() else { return }
    defer { recoverLock.unlock() }
    serversLock.lock()
    let again = servers.filter { stopped.contains($0.name) }
    stopped.subtract(again.map(\.name))
    let list = servers
    let waitingForRelaunch = relaunch
    serversLock.unlock()
    guard !list.isEmpty else { return }
    for server in again {
      note("\(server.name) started again after the App came back")
      _ = runServer(server)
    }
    // Not while start-up models still load (they do not answer yet by design).
    if startupDone.wait(timeout: .now()) == .success {
      startupDone.signal()
      for server in list where !again.contains(where: { $0.name == server.name }) {
        if waitingForRelaunch.contains(server.name) { continue }
        if !healthy(server.port) { note("\(server.name): \(restart(server)) after the App came back") }
      }
    }
    let now = status()
    let answering = (now["servers"] as? [String: Bool] ?? [:])
      .sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    let marked = waitingForRelaunch.isEmpty ? "" : " relaunch=" + waitingForRelaunch.sorted().joined(separator: ",")
    note("foreground: python=\(now["python"] ?? false) \(answering)\(marked); \(memoryNote())")
  }

  /// Starts everything once; returns what was started (or why not), numbers and
  /// file names only. The models load behind the listening Python servers:
  /// requests get the usual "not ready yet" replies until they answer.
  /// decisionModel: "classifier" (default since 2026-11-13, option B': no decision
  /// model, the decision classifier instead) or "ministral"; anything else counts as
  /// "ministral" (Dart sends only known values: portal_assistant/app/lib/service/assistant_on_device.dart).
  func start(decisionModel: String = "classifier") -> String {
    lock.lock()
    defer { lock.unlock() }
    if let state { return state }
    let info = launch(classifierMode: decisionModel == "classifier")
    state = info
    note(info)
    return info
  }

  private func launch(classifierMode: Bool) -> String {
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
      return "not embedded: build with ios/OnDevice/ (portal_assistant/native/ios/setup_ios_on_device.sh)"
    }
    // Without the model files (not downloaded yet) Python still starts, so the App
    // can show and run the download (portal_assistant/docs/AI_MODEL_DOWNLOAD.md); ensureServer then
    // starts each server once its file is in place. Pushed files work as before.

    // Everything the servers and Python print goes to one log the Mac can copy
    // back (Library/Caches/on_device_assistant.log, this launch); release iOS shows no stdout.
    // The previous launches' logs are kept: after a failure the App is usually started
    // again, which used to overwrite the only record of what went wrong. Five launches
    // (2026-11-18; two were not enough: the log of the launch that crashed on 2026-11-18
    // had been overwritten): .log (this one), .prev.log, .prev2.log, .prev3.log, .prev4.log.
    let logURL = caches.appendingPathComponent("on_device_assistant.log")
    let logs = [logURL] + (1...4).map {
      caches.appendingPathComponent($0 == 1 ? "on_device_assistant.prev.log" : "on_device_assistant.prev\($0).log")
    }
    try? fileManager.removeItem(at: logs[4])
    for index in stride(from: 3, through: 0, by: -1) {
      try? fileManager.moveItem(at: logs[index], to: logs[index + 1])
    }
    let log = logURL.path
    // One empty file, then both streams in append mode (2026-11-16): stdout opened with "w"
    // and stderr with "a" had two file offsets, so stdout wrote from the start of the file
    // over what stderr had appended, and lines came out of order. With "a" every write
    // (O_APPEND) goes to the current end of the file, whichever stream or thread makes it.
    _ = fileManager.createFile(atPath: log, contents: nil)
    if freopen(log, "a", stdout) != nil { setvbuf(stdout, nil, _IOLBF, 0) }
    if freopen(log, "a", stderr) != nil { setvbuf(stderr, nil, _IONBF, 0) }
    recordLaunch(caches: caches, whisper: "\(frameworks)/WhisperServer.framework/WhisperServer")

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
        "decision_model=\(classifierMode ? "'classifier'" : "'ministral'")",
        // Model downloads (models.py): where they go, the phone's total memory for
        // the tier, and how Python asks for a server once its file has arrived.
        "models_dir=\(pythonString(models.path))",
        "ram_mb=\(ProcessInfo.processInfo.physicalMemory >> 20)",
        "platform='ios'",
        "server_starter=device_main.native_server_starter(\(UInt(bitPattern: unsafeBitCast(serverStarter, to: Int.self))))",
        // A server that stopped answering is started again (restartServer), and speech
        // passes wait while the App is in the background (isActive): 2026-11-13.
        "server_restarter=device_main.native_server_starter(\(UInt(bitPattern: unsafeBitCast(serverRestarter, to: Int.self))))",
        "app_active=device_main.native_flag(\(UInt(bitPattern: unsafeBitCast(appActiveFlag, to: Int.self))))",
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
    // Same settings as Android: one 2048-token slot per decision policy kept in
    // the prompt cache, no host-RAM prompt cache, no thinking block.
    let decision = Server(
      name: "llama-decision", library: llama, symbol: "townpass_llama_server", port: Self.modelPort,
      arguments: serverArguments(models, Self.modelFile, Self.modelPort)
        + ["-t", threads, "-c", "6144", "-np", "3", "--cache-ram", "0",
           "--reasoning", "off", "--no-webui"],
      file: Self.modelFile)
    let multi = Server(
      name: "whisper-multilingual", library: whisper, symbol: "townpass_whisper_server",
      port: Self.multiWhisperPort,
      arguments: serverArguments(models, Self.multiAsrFile, Self.multiWhisperPort)
        + ["-t", threads, "-l", "auto"],
      file: Self.multiAsrFile)
    // Detection only (encoder + one step): on the CPU (-ng), ~0.2 s a clip,
    // and one GPU context fewer.
    let langid = Server(
      name: "whisper-langid", library: whisper, symbol: "townpass_whisper_server",
      port: Self.gateWhisperPort,
      arguments: serverArguments(models, Self.gateAsrFile, Self.gateWhisperPort)
        + ["-t", threads, "-l", "auto", "-ng"],
      file: Self.gateAsrFile)
    // On the CPU (--device none, 2026-11-10): the backend builds its semantic index
    // with this server in the first minute after launch, and iOS refuses GPU work
    // from an App in the background, so locking the phone then could stop it. A
    // small model: one query is fast on the CPU, and the index is cached after.
    let embedding = Server(
      name: "llama-embedding", library: llama, symbol: "townpass_llama_server",
      port: Self.faqEmbedPort,
      arguments: serverArguments(models, Self.faqModelFile, Self.faqEmbedPort)
        + ["--embedding", "--pooling", "mean", "-c", "512", "-b", "512", "-ub", "512",
           "-np", "1", "-t", "2", "--device", "none", "--no-webui"],
      file: Self.faqModelFile)
    // Option B': the decision classifier instead of the decision model, on the CPU like
    // e5 (a small model; one GPU context fewer). Four 512-token slots score a decision's
    // (request, page) pairs together. --pooling rank: the GGUF does not say its pooling.
    let classifier = Server(
      name: "llama-classifier", library: llama, symbol: "townpass_llama_server",
      port: Self.classifierPort,
      arguments: serverArguments(models, Self.classifierModelFile, Self.classifierPort)
        + ["--reranking", "--pooling", "rank", "-c", "2048", "-np", "4", "-b", "512", "-ub", "512",
           "-t", "2", "--device", "none", "--no-webui"],
      file: Self.classifierModelFile)
    serversLock.lock()
    // One decision server per build: ensureServer("decision") fails in classifier mode.
    planned = ["multilingual": multi, "gate": langid, "embedding": embedding]
    if classifierMode {
      planned["classifier"] = classifier
    } else {
      planned["decision"] = decision
    }
    serversLock.unlock()
    // The ones whose files are here now; the others start once downloaded (ensureServer).
    var plan: [Server] = []
    if classifierMode {
      if has(Self.classifierModelFile) { plan.append(classifier) }
    } else if has(Self.modelFile) {
      plan.append(decision)
    }
    if multilingual { plan.append(multi) }
    if gate { plan.append(langid) }
    if faq { plan.append(embedding) }
    let starter = Thread { [self] in
      for server in plan {
        let began = Date()
        guard runServer(server) else { continue }
        // Ready = model loaded. whisper-server listens only after loading, but
        // llama-server listens at once and answers /health with 503 until its model
        // is loaded; starting the next model before that overlapped their GPU set-up
        // and the App crashed (2026-11-08).
        let llama = server.llama
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

  /// Logs how the previous launch ended (its lifecycle record) and starts this launch's
  /// record. A launch that ended while a whisper-server was restarting (it frees its model
  /// in the App) marks this WhisperServer build unsafe to restart: from then on a failed
  /// whisper-server asks for the App to be opened again instead (restart).
  private func recordLaunch(caches: URL, whisper: String) {
    let fileManager = FileManager.default
    let stateFile = caches.appendingPathComponent("on_device_assistant.state")
    let unsafeFile = caches.appendingPathComponent("on_device_assistant.restart-unsafe")
    let attributes = try? fileManager.attributesOfItem(atPath: whisper)
    let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    let build = "\(size)-\(Int(modified))"
    let previous = previousLaunch(stateFile)
    note("previous launch: \(previous.summary)")
    // The build that crashed, not this one: an update since then starts clean.
    if !previous.restarting.isEmpty && !previous.build.isEmpty {
      try? previous.build.write(to: unsafeFile, atomically: true, encoding: .utf8)
    }
    let unsafeBuild = (try? String(contentsOf: unsafeFile, encoding: .utf8)) ?? ""
    let unsafe = !unsafeBuild.isEmpty && unsafeBuild == build
    let current = isActive() ? "active" : "inactive"
    stateLock.lock()
    whisperBuild = build
    restartUnsafe = unsafe
    stateURL = stateFile
    phase = current
    restartingName = ""
    writeState()
    stateLock.unlock()
    if unsafe {
      note("speech models are not restarted inside the App with this WhisperServer build "
        + "(a launch ended while one was restarting); a failed one asks for the App to be opened again")
    }
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
    loadLock.lock()
    defer { loadLock.unlock() }
    let began = Date()
    if !taiwaneseStarted {
      // A large Whisper model needs taiwaneseOverhead besides its weights (kv caches 343 MB,
      // four Metal compute buffers 335 MB; see taiwaneseOverhead). The App's budget must keep
      // taiwaneseMargin on top: with 68 MB to spare the load ran out of memory, whisper.cpp
      // aborted and the whole App closed (iPhone 17 Pro Max, budget 2,247 MB, 2026-11-13).
      guard memoryAllows(size, for: "taiwanese speech", overhead: Self.taiwaneseOverhead,
                         margin: Self.taiwaneseMargin)
      else { return "memory" }
      guard
        runServer(
          Server(
            name: Self.taiwaneseName, library: whisper, symbol: "townpass_whisper_server",
            port: Self.taiwaneseWhisperPort,
            // -bo 1: one decoder per temperature, so the KV cache is never re-created at 4x.
            arguments: serverArguments(models, Self.taiwaneseAsrFile, Self.taiwaneseWhisperPort)
              + ["-t", whisperThreads, "-l", "zh", "-bo", "1"],
            file: Self.taiwaneseAsrFile))
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

  /// Whether a model of size bytes can load now. On the GPU it takes its weights (the
  /// file) plus ~600 MB of caches and compute buffers (Breeze: kv cross 1500 x 32
  /// layers, decode). Android's CPU figure (1.28x the file) over-counted and refused
  /// a 12 GB iPhone with 2.8 GB free. Both limits must allow it: the App's own budget
  /// (os_proc_available_memory) and the phone's free physical memory. Model weights
  /// on the GPU are wired memory that the App's budget does not count: on an 8 GB
  /// iPhone 17 the budget said 4.5 GB free while the phone had 54 MB left, and iOS
  /// killed the App for page shortage (vm-pageshortage) as Breeze loaded (2026-11-08).
  /// overhead: what the model needs besides its file (default the earlier 600 MB);
  /// margin: what must stay free in the App's budget after it (an allocation that
  /// fails inside whisper.cpp or llama.cpp aborts the whole App). The address space
  /// is checked too (addressSpaceAllows): the two crashes on 2026-11-13 both stopped
  /// at 10.4 GB of used address space.
  private func memoryAllows(
    _ size: UInt64, for label: String, overhead: UInt64 = 600 << 20, margin: UInt64 = 0
  ) -> Bool {
    let needed = size + overhead
    let budget = UInt64(os_proc_available_memory())
    let physical = reclaimableMemory()
    let reserve: UInt64 = 400 * 1024 * 1024  // iOS and its services
    let space = addressSpaceAllows(file: size, rest: overhead + margin)
    note(
      "\(label): needs \(needed >> 20) MB + \(margin >> 20) MB margin; app budget \(budget >> 20) MB, "
        + "phone free \(physical >> 20) MB (keeps \(reserve >> 20) MB), address space \(space ? "ok" : "short")")
    return budget >= needed + margin && physical >= needed + reserve && space
  }

  /// Whether the address space has room for the model now: reserves (without using
  /// memory: PROT_NONE) one block of the file's size, as its weights buffer is one
  /// allocation, plus the rest in 64 MB blocks, then releases them all.
  private func addressSpaceAllows(file: UInt64, rest: UInt64) -> Bool {
    var blocks: [(UnsafeMutableRawPointer, Int)] = []
    defer { for (pointer, length) in blocks { munmap(pointer, length) } }
    var sizes = [Int(file)]
    let block = 64 << 20
    sizes += Array(repeating: block, count: Int((rest + UInt64(block) - 1) / UInt64(block)))
    for length in sizes {
      guard let pointer = mmap(nil, length, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0),
        pointer != UnsafeMutableRawPointer(bitPattern: -1)
      else { return false }
      blocks.append((pointer, length))
    }
    return true
  }

  /// Starts a start-up server whose model file arrived after launch: the App downloads
  /// the models (portal_assistant/docs/AI_MODEL_DOWNLOAD.md) and device_main.Activator calls this through
  /// serverStarter with "decision", "multilingual", "gate", "embedding" or "classifier"
  /// (option B' builds only), on a backend
  /// thread. Waits until the model has loaded. Returns "ready" (also when it already
  /// runs), "missing" (no file), "memory" (not enough free memory now; Python tries
  /// again with the next file or launch) or "failed", like Android's ensureServer.
  func ensureServer(_ name: String) -> String {
    serversLock.lock()
    let server = planned[name]
    let running = server.map { candidate in
      servers.contains { $0.name == candidate.name } && !stopped.contains(candidate.name)
    } ?? false
    serversLock.unlock()
    guard let server, let file = server.file, let models = modelsDirectory else { return "failed" }
    func ready() -> Bool { server.llama ? healthy(server.port) : listening(server.port) }
    if ready() { return "ready" }
    guard
      let size = (try? FileManager.default.attributesOfItem(
        atPath: models.appendingPathComponent(file).path))?[.size] as? UInt64
    else { return "missing" }
    // Not while the start-up models are still loading, and one load at a time.
    if startupDone.wait(timeout: .now() + 300) == .success { startupDone.signal() }
    loadLock.lock()
    defer { loadLock.unlock() }
    let began = Date()
    if !running {
      guard memoryAllows(size, for: server.name) else { return "memory" }
      guard runServer(server) else { return "failed" }
    }
    while Date().timeIntervalSince(began) < 180 {
      if ready() {
        note(String(format: "%@ started after download in %.1f s; %@", server.name,
                    Date().timeIntervalSince(began), memoryNote()))
        return "ready"
      }
      Thread.sleep(forTimeInterval: 0.25)
    }
    return "failed"
  }

  /// The backend's call when a server stopped answering (device_main.Restarter through
  /// serverRestarter): name is an ensureServer name or "taiwanese", with ":error" when the
  /// server answers /health but fails requests (restarted anyway). Returns "ready" (it
  /// answers), "restarted", "busy" (a model is loading, or the server has a clip in progress;
  /// asked again later), "inactive" (the App is not active: nothing is restarted then),
  /// "relaunch" (not restarted inside the App; speech asks for the App to be opened again)
  /// or "failed".
  func restartServer(_ request: String) -> String {
    // runServer would only wait for the foreground, and a model loaded while iOS refuses
    // GPU work would fail again (2026-11-18).
    guard isActive() else {
      note("restart of \(request) asked while the App is not active; not now")
      return "inactive"
    }
    let parts = request.split(separator: ":", maxSplits: 1).map(String.init)
    let name = parts.first ?? ""
    let failing = parts.count > 1 && parts[1] == "error"
    serversLock.lock()
    let wanted: String? = name == "taiwanese" ? Self.taiwaneseName : planned[name]?.name
    let server = servers.first { $0.name == wanted }
    serversLock.unlock()
    guard let server else { return "failed" }  // never started: nothing to restart
    return restart(server, failing: failing)
  }

  /// Gets a started server that does not answer GET /health going again. The patched
  /// servers bind a reclaimed port again within about a second, so first a short wait;
  /// then a server whose thread gave up is run again, and a whisper-server is stopped
  /// (townpass_whisper_server_stop, which frees its model) so that runServer's loop runs
  /// it again. A llama-server cannot be stopped inside the App (its shutdown hook is
  /// process-wide): it is reported, and the backend keeps not waiting for it (liveness.py)
  /// until the App is started again. Running a second copy on the same port was left out:
  /// the old copy's memory would stay allocated.
  /// 2026-11-18 (the App crashed in whisper_free while restarting whisper-multilingual after
  /// it came back from another App): a whisper-server is stopped only while the App is active,
  /// one at a time (loadLock), when it has no clip in progress (townpass_whisper_server_busy),
  /// and only with a WhisperServer that carries the free fix (townpass_whisper_server_fixes);
  /// otherwise, or when a launch of this build already ended during such a restart, it is
  /// marked for an App relaunch (needsRelaunch) and its model is never freed inside the App.
  private func restart(_ server: Server, failing: Bool = false) -> String {
    let began = Date()
    while !failing && Date().timeIntervalSince(began) < 3 {
      if healthy(server.port) { return "ready" }
      Thread.sleep(forTimeInterval: 0.25)
    }
    guard isActive() else {
      note("\(server.name) does not answer; not restarted while the App is not active")
      return "inactive"
    }
    serversLock.lock()
    let marked = relaunch.contains(server.name)
    serversLock.unlock()
    if marked { return "relaunch" }
    // One model load at a time; a load in progress is not interrupted.
    guard loadLock.try() else { return "busy" }
    defer { loadLock.unlock() }
    serversLock.lock()
    let gaveUp = stopped.remove(server.name) != nil
    serversLock.unlock()
    if gaveUp {
      note("\(server.name) had stopped; running it again")
      guard runServer(server) else { return "failed" }
    } else if !server.llama {
      if let why = whisperRestartRefused() { return needsRelaunch(server, why) }
      guard let stop = whisperStop() else { return needsRelaunch(server, "no townpass_whisper_server_stop") }
      let busy = whisperBusy(server.port)
      if busy > 0 {
        note("\(server.name) does not answer but has \(busy) clip(s) in progress; not restarted now")
        return "busy"
      }
      note("\(server.name) \(failing ? "fails its clips" : "does not answer"); stopping it to run it again; "
        + memoryNote())
      // Kept until it answers again: a launch that ends meanwhile (a crash while the model
      // is freed or loaded) turns in-App restarts off for this build (recordLaunch).
      recordRestart(server.name)
      guard stop(Int32(server.port)) == 1 else {
        recordRestart(nil)
        return "failed"
      }
    } else {
      note("\(server.name) does not answer and cannot be restarted inside the App; \(memoryNote())")
      return "failed"
    }
    defer { recordRestart(nil) }
    let restarted = Date()
    while Date().timeIntervalSince(restarted) < 60 {
      if healthy(server.port) {
        note(String(format: "%@ answers again after %.1f s; %@", server.name,
                    Date().timeIntervalSince(restarted), memoryNote()))
        return "restarted"
      }
      Thread.sleep(forTimeInterval: 0.25)
    }
    note("\(server.name) did not answer within 60 s of its restart")
    return "failed"
  }

  /// Why a whisper-server must not be stopped inside the App (nil: it may be). Stopping frees
  /// its model (whisper_free); before the 2026-11-18 patch a clip whose KV cache could not be
  /// re-created had already freed the state, so that free crashed the App.
  private func whisperRestartRefused() -> String? {
    stateLock.lock()
    let unsafe = restartUnsafe
    stateLock.unlock()
    if unsafe { return "a launch of this WhisperServer build ended while one was restarting" }
    guard let address = whisperFunction("townpass_whisper_server_fixes") else {
      return "this WhisperServer is older than the 2026-11-18 free fix"
    }
    let fixes = unsafeBitCast(address, to: WhisperFixes.self)()
    return fixes >= 1 ? nil : "this WhisperServer is older than the 2026-11-18 free fix"
  }

  /// Marks a server that is not restarted inside the App: the backend then answers its clips
  /// with "open the App again" (device_main.Restarter, asr_server.RelaunchNeeded), and
  /// recover() and status() leave it alone until the App is started again.
  private func needsRelaunch(_ server: Server, _ why: String) -> String {
    serversLock.lock()
    relaunch.insert(server.name)
    serversLock.unlock()
    note("\(server.name) fails and is not restarted inside the App (\(why)); speech needs the App opened again")
    return "relaunch"
  }

  /// Clips the whisper-server on port is handling now; 0 when the framework cannot tell.
  private func whisperBusy(_ port: Int) -> Int {
    guard let address = whisperFunction("townpass_whisper_server_busy") else { return 0 }
    return Int(unsafeBitCast(address, to: WhisperBusy.self)(Int32(port)))
  }

  private func whisperStop() -> WhisperStop? {
    guard let address = whisperFunction("townpass_whisper_server_stop") else { return nil }
    return unsafeBitCast(address, to: WhisperStop.self)
  }

  /// A symbol of WhisperServer.framework (already open once a whisper-server runs), or nil.
  private func whisperFunction(_ symbol: String) -> UnsafeMutableRawPointer? {
    guard let library = whisperLibrary, let handle = dlopen(library, RTLD_NOW | RTLD_LOCAL) else { return nil }
    return dlsym(handle, symbol)
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
  private func runServer(_ server: Server) -> Bool {
    let name = server.name
    guard let handle = dlopen(server.library, RTLD_NOW | RTLD_LOCAL),
      let address = dlsym(handle, server.symbol)
    else {
      note("cannot open \(name) (\(String(cString: dlerror())))")
      return false
    }
    serversLock.lock()
    if !servers.contains(where: { $0.name == name }) { servers.append(server) }
    serversLock.unlock()
    // The whisper-servers' pause flag follows the App from now on (setActive); set it to
    // the App's state now, in case the App left the foreground before WhisperServer opened.
    if !server.llama, let pauseAddress = dlsym(handle, "townpass_whisper_server_pause") {
      let pause = unsafeBitCast(pauseAddress, to: WhisperPause.self)
      activeLock.lock()
      whisperPause = pause
      pause(activeNow ? 0 : 1)
      activeLock.unlock()
    }
    let main = unsafeBitCast(address, to: ServerMain.self)
    let argv = ([name] + server.arguments).map { strdup($0) }
    // When iOS reclaims a suspended App's listening socket, llama-server and
    // whisper-server bind the same port again by themselves, keeping the model
    // loaded (portal_assistant/native/ios/llama-server-rebind.patch, whisper-server-ios.patch).
    // Unpatched whisper-server returned from main() instead and reloaded its model
    // on every resume (Breeze: 1.6 GB). A server that still exits is run again once
    // the App is active: every server, the decision model and e5 included (until
    // 2026-11-10 only whisper-server was, and a stopped decision model stayed down
    // until the App was killed). Quick repeated exits stop after five tries; the
    // server is then run again the next time the App comes back (recover()).
    let thread = Thread { [self] in
      var quickExits = 0
      while true {
        let began = Date()
        var pointers: [UnsafeMutablePointer<CChar>?] = argv + [nil]
        let code = main(Int32(argv.count), &pointers)
        note("\(name) exited with \(code) (App \(appIsActive() ? "active" : "not active"))")
        quickExits = Date().timeIntervalSince(began) < 10 ? quickExits + 1 : 0
        if quickExits >= 5 {
          note("\(name) keeps exiting; run again when the App comes back")
          serversLock.lock()
          stopped.insert(name)
          serversLock.unlock()
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
  /// portal_assistant/backend, then device_main.start(...). Returns an error text, or nil.
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

/// The C function the backend calls to start a server once its model file has been
/// downloaded (device_main.native_server_starter -> OnDeviceAssistant.ensureServer).
/// The name is "decision", "multilingual", "gate", "embedding" or "classifier"; ctypes copies the
/// returned text (a few bytes per downloaded file are not freed).
private let serverStarter: @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? = { name in
  strdup(OnDeviceAssistant.shared.ensureServer(name.map { String(cString: $0) } ?? ""))
}

/// The C function the backend calls when a server stopped answering
/// (device_main.Restarter -> OnDeviceAssistant.restartServer); same shape as serverStarter.
private let serverRestarter: @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? = { name in
  strdup(OnDeviceAssistant.shared.restartServer(name.map { String(cString: $0) } ?? ""))
}

/// 1 while the App is in the foreground (device_main.native_flag; asr_server waits before
/// a speech pass otherwise).
private let appActiveFlag: @convention(c) () -> Int32 = {
  OnDeviceAssistant.shared.isActive() ? 1 : 0
}
