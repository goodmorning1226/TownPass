import 'package:get/get.dart';
import 'package:town_pass/service/assistant_speech_language.dart';
import 'package:town_pass/service/page_translation.dart';

/// An example shown before the first message and the reviewed, enabled
/// capability it leads to (null: the capability list itself).
typedef AssistantSuggestion = ({String text, String? capability});

/// The assistant panel's own fixed texts in every page language. Replies come
/// from the backend in the reply language; these are the App's labels, hints
/// and status lines around them. `{name}` marks a placeholder.
abstract final class AssistantTexts {
  /// Languages with a full set of texts; 'zh' is the original and fallback.
  static const languages = ['zh', 'en', 'ja', 'vi', 'id', 'th'];

  /// The language of the current conversation: the menu choice, or the
  /// language last spoken or typed (set through [follow]).
  static final conversation = RxnString();

  /// The conversation language became [code]: a concrete menu pick (either
  /// assistant, or AI 助理設定 → 助理語言), speech decoded in it, or a typed
  /// sentence the backend answered in it. Everything follows at once: both
  /// assistants' texts, chips and guide cards ([conversation], read by gt())
  /// and every App screen and service page (PageTranslation, which also
  /// restores the original Chinese). Pages switch for this launch only; the
  /// next launch starts in the phone's language. 台語 ('nan') is answered in
  /// Chinese; 自動偵測 and unknown codes keep the current language.
  static void follow(String? code) {
    if (code == null) return;
    final language = AssistantSpeechLanguage.textLanguage(code);
    if (!languages.contains(language)) return;
    conversation.value = language;
    if (PageTranslation.languages.containsKey(language)) {
      PageTranslation.instance.setLanguage(language);
    }
  }

  /// The panel's language: the conversation's, else the page language (last
  /// assistant navigation or Settings > Language). Read inside an Obx so the
  /// panel rebuilds when either changes.
  static String get pageLanguage {
    final talking = conversation.value;
    final page = PageTranslation.instance.language.value;
    return languages.contains(talking) ? talking! : page;
  }

  /// [language] when it has texts, otherwise the page language.
  static String resolve(String? language) =>
      languages.contains(language) ? language! : pageLanguage;

  static final _placeholder = RegExp(r'\{(\w+)\}');

  /// The text [key] in [language] (Chinese when missing), with each `{name}`
  /// replaced by `values[name]`. Replaced values are not scanned again, so a
  /// heard sentence containing braces stays as it was.
  static String text(
    String key,
    String? language, [
    Map<String, Object> values = const {},
  ]) {
    final entry = _texts[key];
    assert(entry != null, 'Unknown assistant text: $key');
    final template = entry?[language] ?? entry?['zh'] ?? key;
    if (values.isEmpty) return template;
    return template.replaceAllMapped(
      _placeholder,
      (match) => values[match[1]]?.toString() ?? match[0]!,
    );
  }

  /// The text [key] in the page language.
  static String page(String key, [Map<String, Object> values = const {}]) =>
      text(key, pageLanguage, values);

  /// Every key, for tests.
  static Iterable<String> get keys => _texts.keys;

  /// The languages [key] is written in, for tests.
  static Iterable<String> languagesOf(String key) => _texts[key]!.keys;

  /// Example sentences per language; each language leads to the same
  /// capabilities (a test checks them against the catalog).
  static List<AssistantSuggestion> suggestionsFor(String language) =>
      suggestions[language] ?? suggestions['zh']!;

  static const suggestions = <String, List<AssistantSuggestion>>{
    'zh': [
      (text: '有哪些功能', capability: null),
      (text: '我要借書', capability: 'library'),
      (text: '我要繳水費', capability: 'fees.water'),
      (text: '臨櫃叫號', capability: 'reservation'),
    ],
    'en': [
      (text: 'What can you do?', capability: null),
      (text: 'I want to borrow a book', capability: 'library'),
      (text: 'Pay my water bill', capability: 'fees.water'),
      (text: 'Counter queue', capability: 'reservation'),
    ],
    'ja': [
      (text: 'どんな機能がありますか', capability: null),
      (text: '本を借りたい', capability: 'library'),
      (text: '水道料金を払いたい', capability: 'fees.water'),
      (text: '窓口の順番待ち', capability: 'reservation'),
    ],
    'vi': [
      (text: 'Bạn có những chức năng gì?', capability: null),
      (text: 'Tôi muốn mượn sách', capability: 'library'),
      (text: 'Tôi muốn trả tiền nước', capability: 'fees.water'),
      (text: 'Lấy số thứ tự tại quầy', capability: 'reservation'),
    ],
    'id': [
      (text: 'Ada fitur apa saja?', capability: null),
      (text: 'Saya mau pinjam buku', capability: 'library'),
      (text: 'Bayar tagihan air', capability: 'fees.water'),
      (text: 'Nomor antrean loket', capability: 'reservation'),
    ],
    'th': [
      (text: 'มีฟังก์ชันอะไรบ้าง', capability: null),
      (text: 'ฉันอยากยืมหนังสือ', capability: 'library'),
      (text: 'จ่ายค่าน้ำ', capability: 'fees.water'),
      (text: 'บัตรคิวที่เคาน์เตอร์', capability: 'reservation'),
    ],
  };

  static const _texts = <String, Map<String, String>>{
    // Panel (assistant_host.dart).
    'title': {
      'zh': '助理',
      'en': 'Assistant',
      'ja': 'アシスタント',
      'vi': 'Trợ lý',
      'id': 'Asisten',
      'th': 'ผู้ช่วย',
    },
    'openHint': {
      'zh': '開啟助理對話',
      'en': 'Open the assistant conversation',
      'ja': 'アシスタントとの会話を開く',
      'vi': 'Mở cuộc trò chuyện với trợ lý',
      'id': 'Buka percakapan asisten',
      'th': 'เปิดการสนทนากับผู้ช่วย',
    },
    'openTooltip': {
      'zh': '開啟助理，長按可移到另一側',
      'en': 'Open the assistant; long-press to move it to the other side',
      'ja': 'アシスタントを開く（長押しで反対側へ移動）',
      'vi': 'Mở trợ lý; nhấn giữ để chuyển sang bên kia',
      'id': 'Buka asisten; tekan lama untuk memindahkannya ke sisi lain',
      'th': 'เปิดผู้ช่วย กดค้างเพื่อย้ายไปอีกด้าน',
    },
    'readAloudOn': {
      'zh': '朗讀回覆：開（點一下關閉）',
      'en': 'Read replies aloud: on (tap to turn off)',
      'ja': '返信の読み上げ：オン（タップでオフ）',
      'vi': 'Đọc to câu trả lời: bật (chạm để tắt)',
      'id': 'Bacakan balasan: aktif (ketuk untuk menonaktifkan)',
      'th': 'อ่านคำตอบออกเสียง: เปิด (แตะเพื่อปิด)',
    },
    'readAloudOff': {
      'zh': '朗讀回覆：關（點一下開啟）',
      'en': 'Read replies aloud: off (tap to turn on)',
      'ja': '返信の読み上げ：オフ（タップでオン）',
      'vi': 'Đọc to câu trả lời: tắt (chạm để bật)',
      'id': 'Bacakan balasan: nonaktif (ketuk untuk mengaktifkan)',
      'th': 'อ่านคำตอบออกเสียง: ปิด (แตะเพื่อเปิด)',
    },
    'close': {
      'zh': '關閉助理',
      'en': 'Close the assistant',
      'ja': 'アシスタントを閉じる',
      'vi': 'Đóng trợ lý',
      'id': 'Tutup asisten',
      'th': 'ปิดผู้ช่วย',
    },
    'youCanSay': {
      'zh': '你可以說…',
      'en': 'You can say…',
      'ja': 'こんなふうに話せます…',
      'vi': 'Bạn có thể nói…',
      'id': 'Anda bisa bilang…',
      'th': 'คุณพูดได้ว่า…',
    },
    'quoted': {
      'zh': '「{text}」',
      'en': '“{text}”',
      'ja': '「{text}」',
      'vi': '“{text}”',
      'id': '“{text}”',
      'th': '“{text}”',
    },
    'intro': {
      'zh': '我會帶你到原本的服務頁面。示範與未串接功能會標示，送出與付款由你自己確認。',
      'en':
          'I will take you to the original service page. Demo and not-yet-connected '
          'features are marked; you confirm any submission or payment yourself.',
      'ja': '元のサービスページにご案内します。デモや未接続の機能には表示があります。送信や支払いはご自身で確認してください。',
      'vi':
          'Tôi sẽ đưa bạn đến trang dịch vụ gốc. Tính năng demo và chưa kết nối '
          'sẽ được đánh dấu; bạn tự xác nhận việc gửi và thanh toán.',
      'id':
          'Saya akan membawa Anda ke halaman layanan aslinya. Fitur demo dan yang '
          'belum terhubung akan ditandai; pengiriman dan pembayaran Anda konfirmasi sendiri.',
      'th':
          'ฉันจะพาคุณไปยังหน้าบริการเดิม ฟีเจอร์สาธิตและที่ยังไม่เชื่อมต่อจะมีป้ายกำกับ '
          'การส่งและการชำระเงินคุณต้องยืนยันเอง',
    },
    'youSaid': {
      'zh': '你說',
      'en': 'You said',
      'ja': 'あなた',
      'vi': 'Bạn nói',
      'id': 'Anda',
      'th': 'คุณพูด',
    },
    'assistantReply': {
      'zh': '助理回覆',
      'en': 'Assistant reply',
      'ja': 'アシスタントの返信',
      'vi': 'Trợ lý trả lời',
      'id': 'Balasan asisten',
      'th': 'คำตอบของผู้ช่วย',
    },
    'chooseHint': {
      'zh': '可以點選，或說出／打出編號，例如「第 1 個」。',
      'en': 'Tap one, or say or type its number, e.g. “1”.',
      'ja': 'タップするか、番号を話すか入力してください（例：「1」）。',
      'vi': 'Chạm để chọn, hoặc nói hay gõ số, ví dụ “1”.',
      'id': 'Ketuk salah satu, atau ucapkan/ketik nomornya, misalnya “1”.',
      'th': 'แตะเพื่อเลือก หรือพูด/พิมพ์หมายเลข เช่น “1”',
    },
    'optionNumber': {
      'zh': '第 {n} 項',
      'en': 'Option {n}',
      'ja': '{n} 番目',
      'vi': 'Mục {n}',
      'id': 'Opsi {n}',
      'th': 'ตัวเลือกที่ {n}',
    },
    'previousPage': {
      'zh': '上一頁',
      'en': 'Previous page',
      'ja': '前のページ',
      'vi': 'Trang trước',
      'id': 'Halaman sebelumnya',
      'th': 'หน้าก่อนหน้า',
    },
    'nextPage': {
      'zh': '下一頁',
      'en': 'Next page',
      'ja': '次のページ',
      'vi': 'Trang sau',
      'id': 'Halaman berikutnya',
      'th': 'หน้าถัดไป',
    },
    'pageOf': {
      'zh': '第 {current}／{count} 頁',
      'en': 'Page {current} of {count}',
      'ja': '{current}／{count} ページ',
      'vi': 'Trang {current}/{count}',
      'id': 'Halaman {current} dari {count}',
      'th': 'หน้า {current}/{count}',
    },
    'processing': {
      'zh': '正在處理…',
      'en': 'Working on it…',
      'ja': '処理中…',
      'vi': 'Đang xử lý…',
      'id': 'Sedang diproses…',
      'th': 'กำลังดำเนินการ…',
    },
    // Model downloads on the phone (AssistantModelDownload, docs/AI_MODEL_DOWNLOAD.md).
    'modelsTitle': {
      'zh': '下載離線助理',
      'en': 'Download the offline assistant',
      'ja': 'オフラインアシスタントをダウンロード',
      'vi': 'Tải trợ lý ngoại tuyến',
      'id': 'Unduh asisten offline',
      'th': 'ดาวน์โหลดผู้ช่วยแบบออฟไลน์',
    },
    'modelsBody': {
      'zh':
          '助理全部在這支手機上執行，錄音不會上傳。第一次使用要先下載模型，約 {size}。'
          '建議連上 Wi-Fi；下載只在 App 開著時進行，可以隨時暫停。',
      'en':
          'The assistant runs entirely on this phone; recordings are never '
          'uploaded. Before the first use it needs its models, about {size}. '
          'Wi-Fi is recommended; the download runs while the App is open and '
          'can be paused at any time.',
      'ja':
          'アシスタントはすべてこの端末で動き、録音はアップロードされません。'
          '初回はモデル（約 {size}）のダウンロードが必要です。Wi-Fi をおすすめします。'
          'ダウンロードはアプリを開いている間に行われ、いつでも一時停止できます。',
      'vi':
          'Trợ lý chạy hoàn toàn trên điện thoại này, bản ghi âm không được tải lên. '
          'Lần đầu cần tải mô hình, khoảng {size}. Nên dùng Wi-Fi; việc tải chỉ chạy '
          'khi ứng dụng đang mở và có thể tạm dừng bất cứ lúc nào.',
      'id':
          'Asisten berjalan sepenuhnya di ponsel ini; rekaman tidak pernah diunggah. '
          'Sebelum dipakai pertama kali, modelnya perlu diunduh, sekitar {size}. '
          'Disarankan memakai Wi-Fi; unduhan berjalan saat aplikasi terbuka dan bisa '
          'dijeda kapan saja.',
      'th':
          'ผู้ช่วยทำงานบนโทรศัพท์เครื่องนี้ทั้งหมด เสียงที่บันทึกจะไม่ถูกอัปโหลด '
          'ก่อนใช้ครั้งแรกต้องดาวน์โหลดโมเดลประมาณ {size} แนะนำให้ใช้ Wi-Fi '
          'การดาวน์โหลดทำงานขณะเปิดแอปและหยุดชั่วคราวได้ทุกเมื่อ',
    },
    'modelsLite': {
      'zh': '這支手機的記憶體較小，會使用精簡版：多數需求會列出選項讓你選。',
      'en':
          'This phone has less memory, so it gets the lite version: most '
          'requests show options for you to choose from.',
      'ja': 'この端末はメモリが少ないため、ライト版になります。多くの依頼は選択肢から選んでいただきます。',
      'vi': 'Điện thoại này ít bộ nhớ nên dùng bản rút gọn: hầu hết yêu cầu sẽ hiện các lựa chọn để bạn chọn.',
      'id':
          'Memori ponsel ini lebih kecil, jadi memakai versi ringan: sebagian besar '
          'permintaan menampilkan pilihan untuk Anda pilih.',
      'th': 'โทรศัพท์เครื่องนี้มีหน่วยความจำน้อย จึงใช้รุ่นแบบย่อ คำขอส่วนใหญ่จะแสดงตัวเลือกให้คุณเลือก',
    },
    'modelsTaiwanese': {
      'zh': '台語辨識（另外 {size}）',
      'en': 'Taiwanese speech (another {size})',
      'ja': '台湾語の認識（追加 {size}）',
      'vi': 'Nhận dạng tiếng Đài (thêm {size})',
      'id': 'Pengenalan bahasa Taiwan (tambahan {size})',
      'th': 'การรู้จำภาษาไต้หวัน (เพิ่มอีก {size})',
    },
    'modelsDownload': {
      'zh': '下載',
      'en': 'Download',
      'ja': 'ダウンロード',
      'vi': 'Tải xuống',
      'id': 'Unduh',
      'th': 'ดาวน์โหลด',
    },
    'modelsLater': {
      'zh': '稍後',
      'en': 'Later',
      'ja': 'あとで',
      'vi': 'Để sau',
      'id': 'Nanti',
      'th': 'ไว้ทีหลัง',
    },
    'modelsProgress': {
      'zh': '已下載 {done} / {total}（{percent}%）',
      'en': '{done} of {total} downloaded ({percent}%)',
      'ja': '{done} / {total} ダウンロード済み（{percent}%）',
      'vi': 'Đã tải {done} / {total} ({percent}%)',
      'id': '{done} dari {total} terunduh ({percent}%)',
      'th': 'ดาวน์โหลดแล้ว {done} / {total} ({percent}%)',
    },
    'modelsPause': {
      'zh': '暫停',
      'en': 'Pause',
      'ja': '一時停止',
      'vi': 'Tạm dừng',
      'id': 'Jeda',
      'th': 'หยุดชั่วคราว',
    },
    'modelsResume': {
      'zh': '繼續下載',
      'en': 'Resume download',
      'ja': 'ダウンロードを再開',
      'vi': 'Tiếp tục tải',
      'id': 'Lanjutkan unduhan',
      'th': 'ดาวน์โหลดต่อ',
    },
    'modelsPaused': {
      'zh': '已暫停，下次會從中斷的地方繼續。',
      'en': 'Paused. It continues from where it stopped.',
      'ja': '一時停止しました。次回は中断したところから続けます。',
      'vi': 'Đã tạm dừng. Lần sau sẽ tiếp tục từ chỗ dừng.',
      'id': 'Dijeda. Nanti dilanjutkan dari titik berhenti.',
      'th': 'หยุดชั่วคราวแล้ว ครั้งหน้าจะทำต่อจากจุดที่หยุด',
    },
    'modelsDecisionPending': {
      'zh': '理解模型下載中（{percent}%）；在那之前，多數需求會先列出選項讓你選。',
      'en':
          'The understanding model is downloading ({percent}%); until then most '
          'requests show options to choose from.',
      'ja': '理解モデルをダウンロード中（{percent}%）。それまでは多くの依頼で選択肢を表示します。',
      'vi': 'Đang tải mô hình hiểu yêu cầu ({percent}%); trước đó hầu hết yêu cầu sẽ hiện các lựa chọn.',
      'id':
          'Model pemahaman sedang diunduh ({percent}%); sampai selesai, sebagian besar '
          'permintaan menampilkan pilihan.',
      'th': 'กำลังดาวน์โหลดโมเดลทำความเข้าใจ ({percent}%) ระหว่างนี้คำขอส่วนใหญ่จะแสดงตัวเลือกให้เลือก',
    },
    'modelsErrorNetwork': {
      'zh': '網路中斷，下載停止了。已下載的部分會保留，連上網路後再試一次。',
      'en':
          'The connection dropped and the download stopped. What arrived is '
          'kept; try again once you are online.',
      'ja': '通信が切れてダウンロードが止まりました。取得済みの分は残ります。接続後にもう一度お試しください。',
      'vi': 'Mất kết nối nên việc tải đã dừng. Phần đã tải được giữ lại; hãy thử lại khi có mạng.',
      'id':
          'Koneksi terputus dan unduhan berhenti. Bagian yang sudah ada disimpan; '
          'coba lagi setelah terhubung.',
      'th': 'การเชื่อมต่อขาดหายและการดาวน์โหลดหยุดลง ส่วนที่ได้แล้วจะเก็บไว้ ลองอีกครั้งเมื่อเชื่อมต่อได้',
    },
    'modelsErrorStorage': {
      'zh': '手機空間不足：還需要 {size}。清出空間後再試一次。',
      'en': 'Not enough space on the phone: {size} more is needed. Free some space and try again.',
      'ja': '端末の空き容量が足りません。あと {size} 必要です。空きを作ってからもう一度お試しください。',
      'vi': 'Điện thoại không đủ dung lượng: cần thêm {size}. Hãy giải phóng bộ nhớ rồi thử lại.',
      'id': 'Ruang ponsel tidak cukup: perlu {size} lagi. Kosongkan ruang lalu coba lagi.',
      'th': 'พื้นที่ในโทรศัพท์ไม่พอ ต้องการอีก {size} โปรดเพิ่มพื้นที่แล้วลองอีกครั้ง',
    },
    'modelsErrorChecksum': {
      'zh': '下載的檔案沒有通過檢查，已經刪除，請再試一次。',
      'en': 'A downloaded file failed its check and was deleted. Please try again.',
      'ja': 'ダウンロードしたファイルが検証に通らなかったため削除しました。もう一度お試しください。',
      'vi': 'Một tệp tải về không qua kiểm tra và đã bị xóa. Vui lòng thử lại.',
      'id': 'Berkas yang diunduh gagal diperiksa dan sudah dihapus. Silakan coba lagi.',
      'th': 'ไฟล์ที่ดาวน์โหลดไม่ผ่านการตรวจสอบและถูกลบแล้ว โปรดลองอีกครั้ง',
    },
    'modelsErrorSource': {
      'zh': '這個版本還沒有設定模型的下載來源（開發版）。請用 adb／devicectl 推模型，或建置時設定 ASSISTANT_MODEL_BASE_URL。',
      'en':
          'This build has no download source for the models yet (development '
          'build). Push them with adb/devicectl, or build with '
          'ASSISTANT_MODEL_BASE_URL.',
      'ja':
          'このビルドにはモデルのダウンロード元がまだ設定されていません（開発版）。'
          'adb／devicectl で転送するか、ASSISTANT_MODEL_BASE_URL を指定してビルドしてください。',
      'vi':
          'Bản này chưa có nguồn tải mô hình (bản phát triển). Hãy chép bằng adb/devicectl '
          'hoặc build với ASSISTANT_MODEL_BASE_URL.',
      'id':
          'Build ini belum punya sumber unduhan model (build pengembangan). Salin dengan '
          'adb/devicectl, atau build dengan ASSISTANT_MODEL_BASE_URL.',
      'th':
          'รุ่นนี้ยังไม่ได้ตั้งค่าแหล่งดาวน์โหลดโมเดล (รุ่นพัฒนา) โปรดคัดลอกด้วย adb/devicectl '
          'หรือ build พร้อม ASSISTANT_MODEL_BASE_URL',
    },
    'modelsUnavailable': {
      'zh': '這支手機的記憶體不足，無法執行離線助理。',
      'en': 'This phone does not have enough memory for the offline assistant.',
      'ja': 'この端末はメモリが足りないため、オフラインアシスタントを使えません。',
      'vi': 'Điện thoại này không đủ bộ nhớ để chạy trợ lý ngoại tuyến.',
      'id': 'Memori ponsel ini tidak cukup untuk menjalankan asisten offline.',
      'th': 'โทรศัพท์เครื่องนี้มีหน่วยความจำไม่พอสำหรับผู้ช่วยแบบออฟไลน์',
    },
    'modelsRetry': {
      'zh': '再試一次',
      'en': 'Try again',
      'ja': 'もう一度',
      'vi': 'Thử lại',
      'id': 'Coba lagi',
      'th': 'ลองอีกครั้ง',
    },
    'modelsFailed': {
      'zh': '目前無法取得模型下載的狀態，請稍後再試。',
      'en': 'The model download status is not available right now. Try again shortly.',
      'ja': '現在モデルのダウンロード状況を取得できません。しばらくしてからお試しください。',
      'vi': 'Hiện không lấy được trạng thái tải mô hình. Hãy thử lại sau.',
      'id': 'Status unduhan model belum bisa diambil. Coba lagi sebentar lagi.',
      'th': 'ขณะนี้ดูสถานะการดาวน์โหลดโมเดลไม่ได้ โปรดลองใหม่ภายหลัง',
    },
    'modelsSettingsHeader': {
      'zh': '離線模型',
      'en': 'Offline models',
      'ja': 'オフラインモデル',
      'vi': 'Mô hình ngoại tuyến',
      'id': 'Model offline',
      'th': 'โมเดลแบบออฟไลน์',
    },
    'modelsSettingsState': {
      'zh': '這支手機已下載 {have}，還有 {missing} 未下載。',
      'en': '{have} on this phone, {missing} not downloaded yet.',
      'ja': 'この端末に {have}、未ダウンロード {missing}。',
      'vi': 'Đã có {have} trên máy, còn {missing} chưa tải.',
      'id': '{have} sudah ada di ponsel, {missing} belum diunduh.',
      'th': 'มีในโทรศัพท์แล้ว {have} ยังไม่ได้ดาวน์โหลด {missing}',
    },
    'modelsTaiwaneseAdd': {
      'zh': '下載台語辨識（{size}）',
      'en': 'Download Taiwanese speech ({size})',
      'ja': '台湾語の認識をダウンロード（{size}）',
      'vi': 'Tải nhận dạng tiếng Đài ({size})',
      'id': 'Unduh pengenalan bahasa Taiwan ({size})',
      'th': 'ดาวน์โหลดการรู้จำภาษาไต้หวัน ({size})',
    },
    'modelsDelete': {
      'zh': '刪除已下載的模型',
      'en': 'Delete the downloaded models',
      'ja': 'ダウンロードしたモデルを削除',
      'vi': 'Xóa các mô hình đã tải',
      'id': 'Hapus model yang sudah diunduh',
      'th': 'ลบโมเดลที่ดาวน์โหลดแล้ว',
    },
    'modelsDeleteConfirm': {
      'zh': '刪除後要重新下載才能使用助理。確定刪除嗎？',
      'en':
          'The assistant needs them downloaded again afterwards. Delete them?',
      'ja': '削除すると、アシスタントを使うには再ダウンロードが必要です。削除しますか？',
      'vi': 'Sau khi xóa phải tải lại mới dùng được trợ lý. Xóa không?',
      'id': 'Setelah dihapus, asisten perlu diunduh lagi. Hapus sekarang?',
      'th': 'หลังลบต้องดาวน์โหลดใหม่จึงจะใช้ผู้ช่วยได้ ต้องการลบหรือไม่',
    },
    // Right after launch the phone's models are still loading (AssistantReadiness).
    'modelsLoading': {
      'zh': '模型載入中，好了會自動回答…',
      'en': 'The models are loading; the answer follows by itself…',
      'ja': 'モデルを読み込み中です。終わりしだい自動で答えます…',
      'vi': 'Đang tải mô hình, xong sẽ tự trả lời…',
      'id': 'Model sedang dimuat; jawaban menyusul otomatis…',
      'th': 'กำลังโหลดโมเดล เสร็จแล้วจะตอบเอง…',
    },
    // The iPhone's own assistant after the App came back from the background
    // (AssistantOnDevice.reconnecting).
    'reconnecting': {
      'zh': '助理重新連線中…',
      'en': 'Reconnecting the assistant…',
      'ja': 'アシスタントに再接続しています…',
      'vi': 'Đang kết nối lại trợ lý…',
      'id': 'Menghubungkan ulang asisten…',
      'th': 'กำลังเชื่อมต่อผู้ช่วยอีกครั้ง…',
    },
    'cancel': {
      'zh': '取消',
      'en': 'Cancel',
      'ja': 'キャンセル',
      'vi': 'Hủy',
      'id': 'Batal',
      'th': 'ยกเลิก',
    },
    'inputHint': {
      'zh': '輸入想做的事，例如：我要借書',
      'en': 'Type what you want to do, e.g. I want to borrow a book',
      'ja': 'やりたいことを入力（例：本を借りたい）',
      'vi': 'Nhập việc bạn muốn làm, ví dụ: Tôi muốn mượn sách',
      'id': 'Ketik yang ingin dilakukan, misalnya: Saya mau pinjam buku',
      'th': 'พิมพ์สิ่งที่ต้องการทำ เช่น ฉันอยากยืมหนังสือ',
    },
    'send': {
      'zh': '送出',
      'en': 'Send',
      'ja': '送信',
      'vi': 'Gửi',
      'id': 'Kirim',
      'th': 'ส่ง',
    },
    'useVoice': {
      'zh': '改用語音',
      'en': 'Use voice',
      'ja': '音声入力に切り替え',
      'vi': 'Dùng giọng nói',
      'id': 'Pakai suara',
      'th': 'ใช้เสียง',
    },
    'useKeyboard': {
      'zh': '改用鍵盤',
      'en': 'Use keyboard',
      'ja': 'キーボードに切り替え',
      'vi': 'Dùng bàn phím',
      'id': 'Pakai keyboard',
      'th': 'ใช้แป้นพิมพ์',
    },
    'releaseToCancel': {
      'zh': '放開取消',
      'en': 'Release to cancel',
      'ja': '離すとキャンセル',
      'vi': 'Thả ra để hủy',
      'id': 'Lepaskan untuk membatalkan',
      'th': 'ปล่อยเพื่อยกเลิก',
    },
    'tooQuiet': {
      'zh': '聲音有點小，請靠近麥克風說',
      'en': 'A bit quiet. Speak closer to the microphone',
      'ja': '声が小さめです。マイクに近づいて話してください',
      'vi': 'Giọng hơi nhỏ, hãy nói gần micrô hơn',
      'id': 'Suara agak pelan, bicaralah lebih dekat ke mikrofon',
      'th': 'เสียงเบาไป โปรดพูดใกล้ไมโครโฟน',
    },
    'releaseToSend': {
      'zh': '放開送出，往上滑可取消',
      'en': 'Release to send, slide up to cancel',
      'ja': '離すと送信、上にスライドでキャンセル',
      'vi': 'Thả ra để gửi, vuốt lên để hủy',
      'id': 'Lepaskan untuk kirim, geser ke atas untuk batal',
      'th': 'ปล่อยเพื่อส่ง ปัดขึ้นเพื่อยกเลิก',
    },
    'busyCaption': {
      'zh': '處理中，可在上方取消',
      'en': 'Working; you can cancel above',
      'ja': '処理中です。上でキャンセルできます',
      'vi': 'Đang xử lý, có thể hủy ở phía trên',
      'id': 'Sedang diproses, bisa dibatalkan di atas',
      'th': 'กำลังดำเนินการ ยกเลิกได้ด้านบน',
    },
    'holdToTalk': {
      'zh': '按住說話',
      'en': 'Hold to talk',
      'ja': '押したまま話す',
      'vi': 'Nhấn giữ để nói',
      'id': 'Tekan tahan untuk bicara',
      'th': 'กดค้างเพื่อพูด',
    },
    'listeningSemantics': {
      'zh': '正在聽，點兩下送出',
      'en': 'Listening; double-tap to send',
      'ja': '聞いています。ダブルタップで送信',
      'vi': 'Đang nghe, chạm hai lần để gửi',
      'id': 'Mendengarkan, ketuk dua kali untuk kirim',
      'th': 'กำลังฟัง แตะสองครั้งเพื่อส่ง',
    },
    'speechDownloading': {
      'zh': '正在下載中文（台灣）離線語音…',
      'en': 'Downloading offline speech for Chinese (Taiwan)…',
      'ja': '中国語（台湾）のオフライン音声をダウンロード中…',
      'vi': 'Đang tải giọng nói ngoại tuyến tiếng Trung (Đài Loan)…',
      'id': 'Mengunduh suara offline bahasa Mandarin (Taiwan)…',
      'th': 'กำลังดาวน์โหลดเสียงออฟไลน์ภาษาจีน (ไต้หวัน)…',
    },
    'speechDownloadingPercent': {
      'zh': '正在下載中文（台灣）離線語音 {percent}%',
      'en': 'Downloading offline speech for Chinese (Taiwan) {percent}%',
      'ja': '中国語（台湾）のオフライン音声をダウンロード中 {percent}%',
      'vi': 'Đang tải giọng nói ngoại tuyến tiếng Trung (Đài Loan) {percent}%',
      'id': 'Mengunduh suara offline bahasa Mandarin (Taiwan) {percent}%',
      'th': 'กำลังดาวน์โหลดเสียงออฟไลน์ภาษาจีน (ไต้หวัน) {percent}%',
    },
    'speechLanguage': {
      'zh': '說話的語言：{language}',
      'en': 'Speech language: {language}',
      'ja': '話す言語：{language}',
      'vi': 'Ngôn ngữ nói: {language}',
      'id': 'Bahasa bicara: {language}',
      'th': 'ภาษาที่พูด: {language}',
    },
    'autoDetect': {
      'zh': '自動偵測',
      'en': 'Auto-detect',
      'ja': '自動検出',
      'vi': 'Tự động nhận biết',
      'id': 'Deteksi otomatis',
      'th': 'ตรวจจับอัตโนมัติ',
    },
    'autoShort': {
      'zh': '自動',
      'en': 'Auto',
      'ja': '自動',
      'vi': 'Tự động',
      'id': 'Otomatis',
      'th': 'อัตโนมัติ',
    },
    'downloadingTranslation': {
      'zh': '正在下載頁面翻譯模型（約 30 MB），完成後頁面會自動翻譯…',
      'en': 'Downloading the page translation model (about 30 MB); pages will be translated when it is ready…',
      'ja': 'ページ翻訳モデルをダウンロード中（約 30 MB）。完了するとページが翻訳されます…',
      'vi': 'Đang tải mô hình dịch trang (khoảng 30 MB); trang sẽ được dịch khi tải xong…',
      'id': 'Mengunduh model terjemahan halaman (sekitar 30 MB); halaman akan diterjemahkan setelah selesai…',
      'th': 'กำลังดาวน์โหลดโมเดลแปลหน้า (ประมาณ 30 MB) หน้าจะถูกแปลเมื่อเสร็จ…',
    },

    // Status and error lines (assistant_view_controller.dart).
    'opening': {
      'zh': '正在開啟服務頁面…',
      'en': 'Opening the service page…',
      'ja': 'サービスページを開いています…',
      'vi': 'Đang mở trang dịch vụ…',
      'id': 'Membuka halaman layanan…',
      'th': 'กำลังเปิดหน้าบริการ…',
    },
    'pageFailed': {
      'zh': '服務頁面載入失敗，請檢查網路或重新開啟。',
      'en':
          'The service page did not load. Check the network or open it again.',
      'ja': 'サービスページを読み込めませんでした。ネットワークを確認するか、もう一度開いてください。',
      'vi': 'Không tải được trang dịch vụ. Hãy kiểm tra mạng hoặc mở lại.',
      'id': 'Halaman layanan gagal dimuat. Periksa jaringan atau buka lagi.',
      'th': 'โหลดหน้าบริการไม่สำเร็จ โปรดตรวจสอบเครือข่ายหรือเปิดใหม่อีกครั้ง',
    },
    'onlyCount': {
      'zh': '目前只有 {count} 個選項，請說 1 到 {count}，或直接點選。',
      'en': 'There are only {count} options. Say 1 to {count}, or tap one.',
      'ja': '選択肢は {count} 個だけです。1～{count} の番号を言うか、タップしてください。',
      'vi': 'Chỉ có {count} lựa chọn. Hãy nói từ 1 đến {count}, hoặc chạm để chọn.',
      'id': 'Hanya ada {count} pilihan. Ucapkan 1 sampai {count}, atau ketuk salah satu.',
      'th': 'มีเพียง {count} ตัวเลือก โปรดพูด 1 ถึง {count} หรือแตะเลือก',
    },
    'optionUnavailable': {
      'zh': '第 {n} 項「{title}」目前無法使用，請選其他項目。',
      'en': 'Option {n}, “{title}”, is not available right now. Please choose another.',
      'ja': '{n} 番目の「{title}」は現在利用できません。ほかの項目を選んでください。',
      'vi': 'Mục {n} “{title}” hiện không dùng được. Hãy chọn mục khác.',
      'id': 'Opsi {n} “{title}” belum bisa digunakan. Silakan pilih yang lain.',
      'th':
          'ตัวเลือกที่ {n} “{title}” ยังใช้ไม่ได้ในขณะนี้ โปรดเลือกรายการอื่น',
    },
    'numbered': {
      'zh': '第 {n} 項：{text}',
      'en': '{n}. {text}',
      'ja': '{n}. {text}',
      'vi': '{n}. {text}',
      'id': '{n}. {text}',
      'th': '{n}. {text}',
    },
    'speechScheduled': {
      'zh': '離線語音下載已排入系統，可能會等連上 Wi-Fi 才開始。',
      'en': 'The offline speech download is queued; it may wait for Wi-Fi.',
      'ja': 'オフライン音声のダウンロードを予約しました。Wi-Fi に接続するまで始まらない場合があります。',
      'vi': 'Đã xếp lịch tải giọng nói ngoại tuyến; có thể phải chờ đến khi có Wi-Fi.',
      'id': 'Unduhan suara offline sudah dijadwalkan; mungkin menunggu Wi-Fi.',
      'th': 'จัดคิวดาวน์โหลดเสียงออฟไลน์แล้ว อาจรอจนกว่าจะเชื่อมต่อ Wi-Fi',
    },
    'speechReady': {
      'zh': '中文（台灣）離線語音已下載完成，可以按住麥克風說話了。',
      'en': 'Offline speech for Chinese (Taiwan) is ready. Hold the microphone to talk.',
      'ja': '中国語（台湾）のオフライン音声のダウンロードが完了しました。マイクを押したまま話せます。',
      'vi': 'Đã tải xong giọng nói ngoại tuyến tiếng Trung (Đài Loan). Hãy nhấn giữ micrô để nói.',
      'id': 'Suara offline bahasa Mandarin (Taiwan) sudah siap. Tekan tahan mikrofon untuk bicara.',
      'th': 'ดาวน์โหลดเสียงออฟไลน์ภาษาจีน (ไต้หวัน) เสร็จแล้ว กดไมโครโฟนค้างไว้เพื่อพูดได้เลย',
    },
    'speechDownloadFailed': {
      'zh': '離線語音下載失敗。請確認網路後再按一次麥克風重試，或先用鍵盤。',
      'en':
          'The offline speech download failed. Check the network and press the '
          'microphone again, or use the keyboard for now.',
      'ja': 'オフライン音声のダウンロードに失敗しました。ネットワークを確認してもう一度マイクを押すか、キーボードを使ってください。',
      'vi':
          'Tải giọng nói ngoại tuyến thất bại. Hãy kiểm tra mạng rồi nhấn micrô '
          'lần nữa, hoặc dùng bàn phím trước.',
      'id':
          'Unduhan suara offline gagal. Periksa jaringan lalu tekan mikrofon lagi, '
          'atau pakai keyboard dulu.',
      'th': 'ดาวน์โหลดเสียงออฟไลน์ไม่สำเร็จ โปรดตรวจสอบเครือข่ายแล้วกดไมโครโฟนอีกครั้ง หรือใช้แป้นพิมพ์ไปก่อน',
    },
    'cancelled': {
      'zh': '已取消，未開啟新的頁面。',
      'en': 'Cancelled. No new page was opened.',
      'ja': 'キャンセルしました。新しいページは開いていません。',
      'vi': 'Đã hủy, không mở trang mới.',
      'id': 'Dibatalkan. Tidak ada halaman baru yang dibuka.',
      'th': 'ยกเลิกแล้ว ไม่ได้เปิดหน้าใหม่',
    },
    'micPermission': {
      'zh': '需要麥克風權限才能用語音。可以到手機設定開啟，或點右下角鍵盤改用打字。',
      'en':
          'Voice input needs microphone permission. Turn it on in the phone '
          'settings, or tap the keyboard at the bottom right to type.',
      'ja': '音声入力にはマイクの許可が必要です。スマートフォンの設定で許可するか、右下のキーボードで入力してください。',
      'vi':
          'Cần quyền micrô để dùng giọng nói. Hãy bật trong cài đặt điện thoại, '
          'hoặc chạm bàn phím ở góc dưới bên phải để gõ.',
      'id':
          'Input suara memerlukan izin mikrofon. Aktifkan di pengaturan ponsel, '
          'atau ketuk keyboard di kanan bawah untuk mengetik.',
      'th': 'ต้องอนุญาตไมโครโฟนจึงจะใช้เสียงได้ เปิดได้ในการตั้งค่าโทรศัพท์ หรือแตะแป้นพิมพ์ที่มุมขวาล่างเพื่อพิมพ์',
    },
    'noAudio': {
      'zh': '沒有錄到聲音，請按住麥克風再說話，說完放開。',
      'en': 'Nothing was recorded. Hold the microphone while you speak, then release it.',
      'ja': '録音されませんでした。マイクを押したまま話し、話し終えたら離してください。',
      'vi': 'Không ghi được âm thanh. Hãy nhấn giữ micrô khi nói, nói xong thì thả ra.',
      'id': 'Tidak ada suara yang terekam. Tekan tahan mikrofon sambil bicara, lalu lepaskan.',
      'th': 'ไม่ได้บันทึกเสียง โปรดกดไมโครโฟนค้างไว้ขณะพูด แล้วปล่อยเมื่อพูดจบ',
    },
    'silentMic': {
      'zh': '麥克風沒有收到任何聲音。請確認麥克風沒被其他程式占用；用模擬器時請重新開啟它的麥克風設定，或改用鍵盤。',
      'en':
          'The microphone picked up no sound at all. Make sure no other app is '
          'using it; on an emulator, turn its microphone setting on again, or use '
          'the keyboard.',
      'ja': 'マイクに音がまったく届いていません。ほかのアプリがマイクを使っていないか確認してください。エミュレーターの場合はマイク設定をもう一度オンにするか、キーボードを使ってください。',
      'vi':
          'Micrô không nhận được âm thanh nào. Hãy kiểm tra micrô không bị ứng '
          'dụng khác chiếm dụng; nếu dùng trình giả lập, hãy bật lại cài đặt micrô '
          'của nó, hoặc dùng bàn phím.',
      'id':
          'Mikrofon tidak menangkap suara apa pun. Pastikan tidak sedang dipakai '
          'aplikasi lain; di emulator, aktifkan lagi pengaturan mikrofonnya, atau '
          'pakai keyboard.',
      'th': 'ไมโครโฟนไม่ได้รับเสียงใดเลย โปรดตรวจสอบว่าไม่มีแอปอื่นใช้อยู่ หากใช้อีมูเลเตอร์ให้เปิดการตั้งค่าไมโครโฟนอีกครั้ง หรือใช้แป้นพิมพ์',
    },
    'listening': {
      'zh': '正在聽你說的話…',
      'en': 'Listening to what you said…',
      'ja': 'お話を聞き取っています…',
      'vi': 'Đang nghe bạn nói…',
      'id': 'Mendengarkan ucapan Anda…',
      'th': 'กำลังฟังสิ่งที่คุณพูด…',
    },
    'recognitionFailed': {
      'zh': '語音辨識沒有成功，請再說一次，或點右下角鍵盤改用打字。',
      'en':
          'Speech recognition did not work. Please say it again, or tap the '
          'keyboard at the bottom right to type.',
      'ja': '音声を認識できませんでした。もう一度話すか、右下のキーボードで入力してください。',
      'vi':
          'Nhận dạng giọng nói không thành công. Hãy nói lại, hoặc chạm bàn phím '
          'ở góc dưới bên phải để gõ.',
      'id':
          'Pengenalan suara gagal. Silakan ucapkan lagi, atau ketuk keyboard di '
          'kanan bawah untuk mengetik.',
      'th': 'จดจำเสียงไม่สำเร็จ โปรดพูดอีกครั้ง หรือแตะแป้นพิมพ์ที่มุมขวาล่างเพื่อพิมพ์',
    },
    'confirmHeard': {
      'zh': '我聽到「{text}」，是這句嗎？也可以選下面的說法，或再說一次。',
      'en': 'I heard “{text}”. Is that right? You can also pick one below, or say it again.',
      'ja': '「{text}」と聞こえました。合っていますか？下の候補から選ぶか、もう一度話してください。',
      'vi': 'Tôi nghe được “{text}”, đúng không? Bạn cũng có thể chọn bên dưới, hoặc nói lại.',
      'id': 'Saya mendengar “{text}”, benar? Anda juga bisa memilih di bawah, atau ucapkan lagi.',
      'th': 'ฉันได้ยินว่า “{text}” ใช่ไหม เลือกจากด้านล่างหรือพูดอีกครั้งก็ได้',
    },
    'corrected': {
      'zh': '我聽到「{heard}」，當作「{text}」處理；不對的話請再說一次。',
      'en': 'I heard “{heard}” and took it as “{text}”. If that is wrong, please say it again.',
      'ja': '「{heard}」と聞こえたので「{text}」として処理します。違う場合はもう一度話してください。',
      'vi':
          'Tôi nghe được “{heard}” và hiểu là “{text}”; nếu sai, hãy nói lại.',
      'id': 'Saya mendengar “{heard}” dan menganggapnya “{text}”; jika salah, silakan ucapkan lagi.',
      'th': 'ฉันได้ยินว่า “{heard}” และเข้าใจว่า “{text}” ถ้าไม่ถูก โปรดพูดอีกครั้ง',
    },
    'searching': {
      'zh': '正在找合適的頁面，你可以隨時取消。',
      'en': 'Looking for the right page; you can cancel at any time.',
      'ja': 'ぴったりのページを探しています。いつでもキャンセルできます。',
      'vi': 'Đang tìm trang phù hợp, bạn có thể hủy bất cứ lúc nào.',
      'id': 'Mencari halaman yang sesuai; Anda bisa membatalkan kapan saja.',
      'th': 'กำลังหาหน้าที่เหมาะสม ยกเลิกได้ทุกเมื่อ',
    },
    'unavailable': {
      'zh': '助理暫時無法處理，請重試或使用原服務入口。',
      'en':
          'The assistant cannot handle this right now. Try again or use the '
          'service’s usual entry.',
      'ja': 'アシスタントは現在処理できません。もう一度試すか、通常のサービス入口をご利用ください。',
      'vi': 'Trợ lý tạm thời không xử lý được. Hãy thử lại hoặc dùng lối vào dịch vụ thông thường.',
      'id': 'Asisten sedang tidak bisa memproses. Coba lagi atau gunakan menu layanan biasa.',
      'th': 'ผู้ช่วยยังดำเนินการไม่ได้ในขณะนี้ โปรดลองอีกครั้งหรือใช้ทางเข้าบริการปกติ',
    },

    // Connection and format errors (assistant_service.dart).
    'turnTimeout': {
      'zh': '處理時間較長，請重試或從原圖書頁面搜尋。',
      'en':
          'This is taking a while. Try again or search from the library page.',
      'ja': '処理に時間がかかっています。もう一度試すか、図書館のページから検索してください。',
      'vi': 'Việc xử lý mất nhiều thời gian. Hãy thử lại hoặc tìm từ trang thư viện.',
      'id': 'Prosesnya cukup lama. Coba lagi atau cari dari halaman perpustakaan.',
      'th': 'ใช้เวลาประมวลผลนาน โปรดลองอีกครั้งหรือค้นหาจากหน้าห้องสมุด',
    },
    'unreachable': {
      'zh': '連不到電腦上的助理，請確認後端與裝置連線。',
      'en':
          'Cannot reach the assistant on the computer. Check the backend and the '
          'device connection.',
      'ja': 'コンピューター上のアシスタントに接続できません。バックエンドと端末の接続を確認してください。',
      'vi': 'Không kết nối được với trợ lý trên máy tính. Hãy kiểm tra backend và kết nối thiết bị.',
      'id': 'Tidak dapat terhubung ke asisten di komputer. Periksa backend dan koneksi perangkat.',
      'th': 'เชื่อมต่อผู้ช่วยบนคอมพิวเตอร์ไม่ได้ โปรดตรวจสอบแบ็กเอนด์และการเชื่อมต่อของอุปกรณ์',
    },
    // On-device builds (ASSISTANT_ON_DEVICE): the assistant runs on the phone.
    'unreachableOnDevice': {
      'zh': '手機上的助理還在啟動，或剛從背景回來，請稍候幾秒再試一次。',
      'en':
          'The assistant on this phone is still starting or just came back from '
          'the background. Wait a few seconds and try again.',
      'ja': 'この端末のアシスタントは起動中か、バックグラウンドから戻ったところです。数秒待ってからもう一度お試しください。',
      'vi': 'Trợ lý trên điện thoại đang khởi động hoặc vừa quay lại từ nền. Hãy đợi vài giây rồi thử lại.',
      'id': 'Asisten di ponsel ini masih dimulai atau baru kembali dari latar belakang. Tunggu beberapa detik lalu coba lagi.',
      'th': 'ผู้ช่วยในโทรศัพท์กำลังเริ่มทำงานหรือเพิ่งกลับจากเบื้องหลัง โปรดรอสักครู่แล้วลองอีกครั้ง',
    },
    'turnDisconnected': {
      'zh': '助理連線中斷，請重試或使用原服務入口。',
      'en':
          'The connection to the assistant was lost. Try again or use the '
          'service’s usual entry.',
      'ja': 'アシスタントとの接続が切れました。もう一度試すか、通常のサービス入口をご利用ください。',
      'vi': 'Mất kết nối với trợ lý. Hãy thử lại hoặc dùng lối vào dịch vụ thông thường.',
      'id': 'Koneksi ke asisten terputus. Coba lagi atau gunakan menu layanan biasa.',
      'th': 'การเชื่อมต่อกับผู้ช่วยขาดหาย โปรดลองอีกครั้งหรือใช้ทางเข้าบริการปกติ',
    },
    'replyTooLong': {
      'zh': '助理回覆過長，未執行操作。',
      'en': 'The assistant’s reply was too long; nothing was done.',
      'ja': 'アシスタントの返信が長すぎるため、操作は実行していません。',
      'vi': 'Câu trả lời của trợ lý quá dài, chưa thực hiện thao tác nào.',
      'id': 'Balasan asisten terlalu panjang; tidak ada tindakan yang dijalankan.',
      'th': 'คำตอบของผู้ช่วยยาวเกินไป จึงไม่ได้ดำเนินการใด',
    },
    'cannotProcess': {
      'zh': '助理暫時無法處理。',
      'en': 'The assistant cannot handle this right now.',
      'ja': 'アシスタントは現在処理できません。',
      'vi': 'Trợ lý tạm thời không xử lý được.',
      'id': 'Asisten sedang tidak bisa memproses.',
      'th': 'ผู้ช่วยยังดำเนินการไม่ได้ในขณะนี้',
    },
    'replyMismatch': {
      'zh': '助理回覆與本次需求不一致，未執行操作。',
      'en':
          'The assistant’s reply did not match this request; nothing was done.',
      'ja': 'アシスタントの返信が今回の依頼と一致しないため、操作は実行していません。',
      'vi': 'Câu trả lời của trợ lý không khớp với yêu cầu này, chưa thực hiện thao tác nào.',
      'id': 'Balasan asisten tidak sesuai dengan permintaan ini; tidak ada tindakan yang dijalankan.',
      'th': 'คำตอบของผู้ช่วยไม่ตรงกับคำขอนี้ จึงไม่ได้ดำเนินการใด',
    },
    'transcriptionFailed': {
      'zh': '語音辨識沒有成功。',
      'en': 'Speech recognition did not work.',
      'ja': '音声を認識できませんでした。',
      'vi': 'Nhận dạng giọng nói không thành công.',
      'id': 'Pengenalan suara gagal.',
      'th': 'จดจำเสียงไม่สำเร็จ',
    },
    'transcriptionInvalid': {
      'zh': '語音辨識回覆不正確，請再說一次或改用鍵盤。',
      'en': 'The speech recognition reply was not valid. Please say it again or use the keyboard.',
      'ja': '音声認識の応答が正しくありません。もう一度話すか、キーボードを使ってください。',
      'vi': 'Kết quả nhận dạng giọng nói không hợp lệ. Hãy nói lại hoặc dùng bàn phím.',
      'id': 'Hasil pengenalan suara tidak valid. Silakan ucapkan lagi atau pakai keyboard.',
      'th': 'ผลการจดจำเสียงไม่ถูกต้อง โปรดพูดอีกครั้งหรือใช้แป้นพิมพ์',
    },
    'transcriptionTimeout': {
      'zh': '語音辨識時間較長，請再說一次或改用鍵盤。',
      'en': 'Speech recognition is taking a while. Please say it again or use the keyboard.',
      'ja': '音声認識に時間がかかっています。もう一度話すか、キーボードを使ってください。',
      'vi': 'Nhận dạng giọng nói mất nhiều thời gian. Hãy nói lại hoặc dùng bàn phím.',
      'id': 'Pengenalan suara cukup lama. Silakan ucapkan lagi atau pakai keyboard.',
      'th': 'การจดจำเสียงใช้เวลานาน โปรดพูดอีกครั้งหรือใช้แป้นพิมพ์',
    },
    'transcriptionDisconnected': {
      'zh': '助理連線中斷，請再說一次或改用鍵盤。',
      'en': 'The connection to the assistant was lost. Please say it again or use the keyboard.',
      'ja': 'アシスタントとの接続が切れました。もう一度話すか、キーボードを使ってください。',
      'vi': 'Mất kết nối với trợ lý. Hãy nói lại hoặc dùng bàn phím.',
      'id': 'Koneksi ke asisten terputus. Silakan ucapkan lagi atau pakai keyboard.',
      'th': 'การเชื่อมต่อกับผู้ช่วยขาดหาย โปรดพูดอีกครั้งหรือใช้แป้นพิมพ์',
    },
  };
}
