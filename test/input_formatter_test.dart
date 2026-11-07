import 'package:flutter_test/flutter_test.dart';
import 'package:town_pass/page/guided_assistant/model/input_formatter.dart';

/// The floating microphone's field formatter (model/input_formatter.dart):
/// what the user said, written as the page field expects.
void main() {
  String f(String said, FieldKind kind, {DateStyle style = DateStyle.iso}) =>
      InputFormatter.format(
        said,
        kind,
        now: DateTime(2026, 11, 8),
        dateStyle: style,
      );

  group('kind of field', () {
    FieldKind k(FieldInfo info, {FieldKind? hint}) =>
        InputFormatter.kindOf(info, hint: hint);

    test('from the type and input mode', () {
      expect(k(const FieldInfo(type: 'tel')), FieldKind.phone);
      expect(k(const FieldInfo(type: 'email')), FieldKind.email);
      expect(k(const FieldInfo(type: 'number')), FieldKind.number);
      expect(k(const FieldInfo(type: 'date')), FieldKind.date);
      expect(k(const FieldInfo(type: 'time')), FieldKind.time);
      expect(k(const FieldInfo(inputMode: 'tel')), FieldKind.phone);
      expect(k(const FieldInfo(inputMode: 'email')), FieldKind.email);
      expect(k(const FieldInfo(inputMode: 'numeric')), FieldKind.number);
      expect(k(const FieldInfo(tag: 'textarea')), FieldKind.multiline);
      expect(k(const FieldInfo()), FieldKind.text);
    });

    test('from autocomplete and pattern', () {
      expect(k(const FieldInfo(autocomplete: 'tel-national')), FieldKind.phone);
      expect(k(const FieldInfo(autocomplete: 'email')), FieldKind.email);
      expect(k(const FieldInfo(autocomplete: 'bday')), FieldKind.date);
      expect(
        k(const FieldInfo(pattern: r'[A-Z][12]\d{8}')),
        FieldKind.taiwanId,
      );
      expect(k(const FieldInfo(pattern: r'^[A-Z][0-9]{9}$')), FieldKind.text);
      expect(k(const FieldInfo(pattern: r'\d+')), FieldKind.number);
    });

    test('from the name, id, label and placeholder', () {
      expect(k(const FieldInfo(id: 'mobile_number')), FieldKind.phone);
      expect(k(const FieldInfo(name: 'contact_tel')), FieldKind.phone);
      expect(k(const FieldInfo(label: '聯絡電話')), FieldKind.phone);
      expect(k(const FieldInfo(placeholder: '請輸入手機號碼')), FieldKind.phone);
      expect(k(const FieldInfo(id: 'mail')), FieldKind.email);
      expect(k(const FieldInfo(label: '電子信箱')), FieldKind.email);
      expect(k(const FieldInfo(label: '身分證字號')), FieldKind.taiwanId);
      expect(k(const FieldInfo(label: '發生日期')), FieldKind.date);
      expect(k(const FieldInfo(label: '發生時間')), FieldKind.time);
      expect(k(const FieldInfo(placeholder: '請輸入車牌號碼')), FieldKind.code);
      expect(k(const FieldInfo(placeholder: '搜尋案號關鍵字')), FieldKind.code);
      expect(k(const FieldInfo(label: '繳費金額')), FieldKind.number);
      expect(k(const FieldInfo(label: '路燈傾倒(失明盞)')), FieldKind.number);
      expect(k(const FieldInfo(placeholder: '請輸入詳細地址')), FieldKind.text);
      expect(k(const FieldInfo(id: 'hotel')), FieldKind.text);
    });

    test('the step hint wins, but only for the step field', () {
      const box = FieldInfo(placeholder: '請輸入');
      expect(k(box, hint: FieldKind.phone), FieldKind.phone);
      expect(
        InputFormatter.fill('零九一二三四五六七八', box, hint: FieldKind.phone)?.text,
        '零九一二三四五六七八',
        reason: 'not the step field: read from the field itself',
      );
      expect(
        InputFormatter.fill(
          '零九一二三四五六七八',
          const FieldInfo(placeholder: '請輸入', isStep: true),
          hint: FieldKind.phone,
        )?.text,
        '0912345678',
      );
    });

    test('date style from the field', () {
      DateStyle s(FieldInfo i) => InputFormatter.dateStyleOf(i);
      expect(s(const FieldInfo(type: 'date')), DateStyle.iso);
      expect(s(const FieldInfo(placeholder: 'YYYY/MM/DD')), DateStyle.slash);
      expect(s(const FieldInfo(placeholder: '例：2024/03/05')), DateStyle.slash);
      expect(s(const FieldInfo(placeholder: '民國年/月/日')), DateStyle.roc);
      expect(s(const FieldInfo(placeholder: '113/03/05')), DateStyle.roc);
      expect(s(const FieldInfo(placeholder: 'YYYYMMDD')), DateStyle.compact);
      expect(s(const FieldInfo(placeholder: 'yyyy-mm-dd')), DateStyle.iso);
      expect(s(const FieldInfo()), DateStyle.iso);
    });
  });

  group('phone', () {
    test('digits as said', () {
      expect(f('0912345678', FieldKind.phone), '0912345678');
      expect(f('0912-345-678', FieldKind.phone), '0912345678');
      expect(f('0912 345 678', FieldKind.phone), '0912345678');
      expect(f('(02) 2720-8889', FieldKind.phone), '0227208889');
      expect(f('０９１２３４５６７８', FieldKind.phone), '0912345678');
    });

    test('Chinese numerals and spoken digit names', () {
      expect(f('零九一二三四五六七八', FieldKind.phone), '0912345678');
      expect(f('洞九么二三四五六七八', FieldKind.phone), '0912345678');
      expect(f('〇九一二 三四五 六七八', FieldKind.phone), '0912345678');
      expect(f('零九拐拐 兩兩勾勾 洞洞', FieldKind.phone), '0977229900');
      expect(f('我的手機是零九一二，三四五，六七八。', FieldKind.phone), '0912345678');
      expect(f('零二二七二零八八八九', FieldKind.phone), '0227208889');
    });

    test('a 十 in the middle, at the end and at the start', () {
      expect(f('零九三十四', FieldKind.phone), '0934');
      expect(f('零九一二三十', FieldKind.phone), '091230');
      expect(f('十二', FieldKind.phone), '12');
    });

    test('+886 becomes a leading 0', () {
      expect(f('+886 912 345 678', FieldKind.phone), '0912345678');
      expect(f('+886-0912-345-678', FieldKind.phone), '0912345678');
      expect(f('加八八六九一二三四五六七八', FieldKind.phone), '0912345678');
      expect(f('886912345678', FieldKind.phone), '0912345678');
      expect(f('plus 886 2 2720 8889', FieldKind.phone), '0227208889');
    });

    test('English digit words', () {
      expect(
        f('zero nine one two three four five six seven eight', FieldKind.phone),
        '0912345678',
      );
      expect(f('oh nine 12', FieldKind.phone), '0912');
    });
  });

  group('email', () {
    test('小老鼠 and 點', () {
      expect(f('abc小老鼠gmail點com', FieldKind.email), 'abc@gmail.com');
      expect(f('ABC 小老鼠 Gmail 點 COM', FieldKind.email), 'abc@gmail.com');
      expect(f('wang老鼠yahoo點com點tw', FieldKind.email), 'wang@yahoo.com.tw');
      expect(f('chen＠ms1.hinet.net', FieldKind.email), 'chen@ms1.hinet.net');
    });

    test('English words at, dot, underscore, dash', () {
      expect(f('john at gmail dot com', FieldKind.email), 'john@gmail.com');
      expect(
        f('mary underscore lee at taipei dot gov dot tw', FieldKind.email),
        'mary_lee@taipei.gov.tw',
      );
      expect(f('a dash b at x dot org', FieldKind.email), 'a-b@x.org');
      expect(f('Tom.Lin@Gmail.com.', FieldKind.email), 'tom.lin@gmail.com');
    });

    test('Chinese symbols and digits, one @ only', () {
      expect(f('wang底線一二三小老鼠gmail點com', FieldKind.email), 'wang_123@gmail.com');
      expect(f('a@b@c.com', FieldKind.email), 'a@bc.com');
      expect(f('我的信箱是 abc@gmail.com。', FieldKind.email), 'abc@gmail.com');
    });
  });

  group('number', () {
    test('Arabic digits, no units', () {
      expect(f('35', FieldKind.number), '35');
      expect(f('1,200元', FieldKind.number), '1200');
      expect(f('大概 3 盞', FieldKind.number), '3');
      expect(f('５００塊', FieldKind.number), '500');
      expect(f('1.5公尺', FieldKind.number), '1.5');
    });

    test('Chinese numerals with 十百千萬', () {
      expect(f('三十五', FieldKind.number), '35');
      expect(f('十', FieldKind.number), '10');
      expect(f('十五', FieldKind.number), '15');
      expect(f('一百二十三', FieldKind.number), '123');
      expect(f('一千零五', FieldKind.number), '1005');
      expect(f('三萬五千', FieldKind.number), '35000');
      expect(f('一萬二', FieldKind.number), '12000');
      expect(f('三千五', FieldKind.number), '3500');
      expect(f('兩百五', FieldKind.number), '250');
      expect(f('兩百五十元', FieldKind.number), '250');
      expect(f('3萬5千', FieldKind.number), '35000');
      expect(f('3萬5', FieldKind.number), '35000');
      expect(f('一億兩千萬', FieldKind.number), '120000000');
      expect(f('十萬', FieldKind.number), '100000');
      expect(f('一二三', FieldKind.number), '123');
      expect(f('一點五', FieldKind.number), '1.5');
      expect(f('路燈倒了兩盞', FieldKind.number), '2');
    });

    test('nothing to read', () {
      expect(f('不知道', FieldKind.number), '');
      expect(f('', FieldKind.number), '');
    });
  });

  group('date', () {
    test('relative days', () {
      expect(f('今天', FieldKind.date), '2026-11-08');
      expect(f('明天', FieldKind.date), '2026-11-09');
      expect(f('後天', FieldKind.date), '2026-11-10');
      expect(f('大後天', FieldKind.date), '2026-11-11');
      expect(f('昨天', FieldKind.date), '2026-11-07');
      expect(f('前天', FieldKind.date), '2026-11-06');
      expect(f('tomorrow', FieldKind.date), '2026-11-09');
    });

    test('ROC and western years', () {
      expect(f('民國113年3月5日', FieldKind.date), '2024-03-05');
      expect(f('民國一一三年三月五號', FieldKind.date), '2024-03-05');
      expect(f('一百一十三年十二月三十一日', FieldKind.date), '2024-12-31');
      expect(f('2024年3月5日', FieldKind.date), '2024-03-05');
      expect(f('二〇二四年三月五號', FieldKind.date), '2024-03-05');
      expect(f('2024/3/5', FieldKind.date), '2024-03-05');
      expect(f('2024-03-05', FieldKind.date), '2024-03-05');
      expect(f('113/03/05', FieldKind.date), '2024-03-05');
      expect(f('20240305', FieldKind.date), '2024-03-05');
      expect(f('1130305', FieldKind.date), '2024-03-05');
    });

    test('month and day this year, a day this month, English', () {
      expect(f('三月五號', FieldKind.date), '2026-03-05');
      expect(f('十一月二十日', FieldKind.date), '2026-11-20');
      expect(f('5號', FieldKind.date), '2026-11-05');
      expect(f('March 5, 2024', FieldKind.date), '2024-03-05');
      expect(f('5 March', FieldKind.date), '2026-03-05');
    });

    test('in the field style', () {
      expect(f('民國113年3月5日', FieldKind.date, style: DateStyle.slash), '2024/03/05');
      expect(f('2024年3月5日', FieldKind.date, style: DateStyle.roc), '113/03/05');
      expect(f('今天', FieldKind.date, style: DateStyle.compact), '20261108');
    });

    test('impossible or missing dates', () {
      expect(f('2月30日', FieldKind.date), '');
      expect(f('13月1日', FieldKind.date), '');
      expect(f('下次吧', FieldKind.date), '');
    });
  });

  group('time', () {
    test('spoken times', () {
      expect(f('下午三點半', FieldKind.time), '15:30');
      expect(f('早上九點十五分', FieldKind.time), '09:15');
      expect(f('九點零五分', FieldKind.time), '09:05');
      expect(f('晚上八點', FieldKind.time), '20:00');
      expect(f('中午十二點', FieldKind.time), '12:00');
      expect(f('中午一點', FieldKind.time), '13:00');
      expect(f('凌晨十二點', FieldKind.time), '00:00');
      expect(f('三點一刻', FieldKind.time), '03:15');
      expect(f('下午三點三刻', FieldKind.time), '15:45');
      expect(f('14點', FieldKind.time), '14:00');
    });

    test('clock forms and English', () {
      expect(f('15:30', FieldKind.time), '15:30');
      expect(f('3:30 pm', FieldKind.time), '15:30');
      expect(f('9 am', FieldKind.time), '09:00');
      expect(f('7:05', FieldKind.time), '07:05');
    });

    test('no time', () {
      expect(f('等一下', FieldKind.time), '');
      expect(f('25:00', FieldKind.time), '');
    });
  });

  group('Taiwan id', () {
    test('a capital letter and nine digits', () {
      expect(f('A123456789', FieldKind.taiwanId), 'A123456789');
      expect(f('a 1 2 3 4 5 6 7 8 9', FieldKind.taiwanId), 'A123456789');
      expect(f('大寫A一二三四五六七八九', FieldKind.taiwanId), 'A123456789');
      expect(f('F 二三四 五六七 八九零', FieldKind.taiwanId), 'F234567890');
      expect(f('alpha 123456789', FieldKind.taiwanId), 'A123456789');
      expect(f('A1234567890123', FieldKind.taiwanId), 'A123456789');
      expect(f('我的身分證是 B220000000。', FieldKind.taiwanId), 'B220000000');
    });
  });

  group('codes', () {
    test('plates and case numbers', () {
      expect(f('abc-1234', FieldKind.code), 'ABC-1234');
      expect(f('ABC 槓 1234', FieldKind.code), 'ABC-1234');
      expect(f('一一三零三零五零零一', FieldKind.code), '1130305001');
      expect(f('R A B 5678', FieldKind.code), 'RAB5678');
      expect(f('－ab12－', FieldKind.code), 'AB12');
    });
  });

  group('text', () {
    test('as said, without the closing 。 on one line', () {
      expect(f('哈利波特', FieldKind.text), '哈利波特');
      expect(f('市府路一號。', FieldKind.text), '市府路一號');
      expect(f('  台北市 信義區 市府路1號  ', FieldKind.text), '台北市信義區市府路1號');
      expect(f('第一行\n第二行', FieldKind.text), '第一行 第二行');
      expect(f('Harry Potter', FieldKind.text), 'Harry Potter');
    });

    test('Chinese punctuation and Traditional characters', () {
      expect(f('路灯坏了,请尽快处理.', FieldKind.text), '路燈壞了，請盡快處理');
      expect(f('这个问题?', FieldKind.text), '這個問題？');
      expect(f('臺北市', FieldKind.text), '臺北市');
    });

    test('a textarea keeps its closing 。 and lines', () {
      expect(f('路燈壞了。', FieldKind.multiline), '路燈壞了。');
      expect(f('第一行\n第二行', FieldKind.multiline), '第一行\n第二行');
    });
  });

  group('fill', () {
    test('a textarea with text gets the words after it', () {
      final fill = InputFormatter.fill(
        '請盡快處理',
        const FieldInfo(tag: 'textarea', value: '路燈壞了'),
      )!;
      expect(fill.append, isTrue);
      expect(fill.separator, '。');
      expect(fill.text, '請盡快處理');
      final after = InputFormatter.fill(
        'more',
        const FieldInfo(tag: 'textarea', value: '路燈壞了。'),
      )!;
      expect(after.separator, '');
      final english = InputFormatter.fill(
        'second',
        const FieldInfo(tag: 'textarea', value: 'first'),
      )!;
      expect(english.separator, ' ');
      final empty = InputFormatter.fill(
        '路燈壞了',
        const FieldInfo(tag: 'textarea', value: '  '),
      )!;
      expect(empty.append, isFalse);
    });

    test('maxlength is kept', () {
      expect(
        InputFormatter.fill(
          '零九一二三四五六七八九九',
          const FieldInfo(type: 'tel', maxLength: 10),
        )!.text,
        '0912345678',
      );
      expect(
        InputFormatter.fill(
          '請盡快處理',
          const FieldInfo(tag: 'textarea', value: '路燈壞了', maxLength: 7),
        )!.text,
        '請盡',
      );
      expect(
        InputFormatter.fill(
          '再多一點',
          const FieldInfo(tag: 'textarea', value: '已經滿了', maxLength: 4),
        ),
        isNull,
        reason: 'full',
      );
    });

    test('nothing that fits gives null', () {
      expect(
        InputFormatter.fill('我不知道', const FieldInfo(type: 'date')),
        isNull,
      );
      expect(InputFormatter.fill('   ', const FieldInfo()), isNull);
    });

    test('from the JSON the page script returns', () {
      final info = FieldInfo.fromJson({
        'tag': 'INPUT',
        'type': 'TEL',
        'placeholder': '請輸入手機號碼',
        'label': '手機號碼',
        'maxLength': 10,
        'value': '',
        'isStep': true,
        'name': 42,
      });
      expect(info.tag, 'input');
      expect(info.type, 'tel');
      expect(info.maxLength, 10);
      expect(info.name, '');
      expect(info.isStep, isTrue);
      expect(info.title, '手機號碼');
      expect(FieldInfo.fromJson({'maxLength': -1}).maxLength, isNull);
    });
  });
}
