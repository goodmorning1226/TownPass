// The TownPass design tokens the assistant draws with: colours and text
// styles with the same values as the host App's TPColors and TPTextStyles
// (lib/util/tp_colors.dart, tp_text_styles.dart at the official baseline
// e65b586), and AssistantText, a copy of the host's TPText. They are
// constants so the assistant's widgets stay `const`; the host App's test
// test/portal_assistant_host_test.dart fails when the host's values change,
// so a new palette is copied here (portal_assistant/INTEGRATION.md, hook 0).
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:townpass_portal_assistant/service/page_translation.dart';

/// TPColors' values (host lib/util/tp_colors.dart).
abstract final class AssistantColors {
  static const Color primary50 = Color(0xFFEDF8FA);
  static const Color primary100 = Color(0xFFDBF1F5);
  static const Color primary200 = Color(0xFFB4E2EA);
  static const Color primary300 = Color(0xFF93D4DF);
  static const Color primary400 = Color(0xFF71C5D5);
  static const Color primary500 = Color(0xFF5AB4C5);
  static const Color primary600 = Color(0xFF468D9B);
  static const Color primary700 = Color(0xFF356C77);
  static const Color primary800 = Color(0xFF22474E);
  static const Color primary900 = Color(0xFF112629);
  static const Color primary950 = Color(0xFF081315);
  static const Color secondary50 = Color(0xFFFDF8ED);
  static const Color secondary100 = Color(0xFFFCF2DF);
  static const Color secondary200 = Color(0xFFF8E3BC);
  static const Color secondary300 = Color(0xFFF4D69E);
  static const Color secondary400 = Color(0xFFF0C87C);
  static const Color secondary500 = Color(0xFFF5BA4B);
  static const Color secondary600 = Color(0xFFE7A43C);
  static const Color secondary700 = Color(0xFFAD7B2B);
  static const Color secondary800 = Color(0xFF74521B);
  static const Color secondary900 = Color(0xFF3C2B0B);
  static const Color secondary950 = Color(0xFF1C1304);
  static const Color grayscale50 = Color(0xFFF1F3F4);
  static const Color grayscale100 = Color(0xFFE3E7E9);
  static const Color grayscale200 = Color(0xFFCAD1D5);
  static const Color grayscale300 = Color(0xFFADB8BE);
  static const Color grayscale400 = Color(0xFF91A0A8);
  static const Color grayscale500 = Color(0xFF738995);
  static const Color grayscale600 = Color(0xFF5E6D76);
  static const Color grayscale700 = Color(0xFF475259);
  static const Color grayscale800 = Color(0xFF30383D);
  static const Color grayscale900 = Color(0xFF171B1D);
  static const Color grayscale950 = Color(0xFF0B0D0E);
  static const Color red50 = Color(0xFFFAEEEE);
  static const Color red100 = Color(0xFFF5DCDD);
  static const Color red200 = Color(0xFFEBB6B6);
  static const Color red300 = Color(0xFFE29494);
  static const Color red400 = Color(0xFFD45251);
  static const Color red500 = Color(0xFFD45251);
  static const Color red600 = Color(0xFFC2332F);
  static const Color red700 = Color(0xFF912522);
  static const Color red800 = Color(0xFF5F1715);
  static const Color red900 = Color(0xFF310B0B);
  static const Color red950 = Color(0xFF180505);
  static const Color orange50 = Color(0xFFFDF3EC);
  static const Color orange100 = Color(0xFFFBE7D9);
  static const Color orange200 = Color(0xFFF7CFB2);
  static const Color orange300 = Color(0xFFF4B992);
  static const Color orange400 = Color(0xFFF1A26D);
  static const Color orange500 = Color(0xFFFD853A);
  static const Color orange600 = Color(0xFFE6692C);
  static const Color orange700 = Color(0xFFAE501F);
  static const Color orange800 = Color(0xFF713311);
  static const Color orange900 = Color(0xFF391A06);
  static const Color orange950 = Color(0xFF1C0C02);
  static const Color white = Color(0xFFFFFFFF);
  static const Color black = Color(0xFF000000);
  static const Color transparent = Colors.transparent;
}

/// The font family TPTextStyles uses (host fonts/, FontFamily.pingFangTC);
/// the host App declares it in its pubspec.
const assistantFontFamily = 'PingFangTC';

/// TPTextStyles' values (host lib/util/tp_text_styles.dart).
abstract final class AssistantTextStyles {
  static const TextStyle h1Regular = TextStyle(
    fontSize: 36.0,
    fontFamily: assistantFontFamily,
    fontWeight: FontWeight.w400,
  );
  static const TextStyle h1SemiBold = TextStyle(
    fontSize: 36,
    fontFamily: assistantFontFamily,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle h2Regular = TextStyle(
    fontSize: 24,
    fontFamily: assistantFontFamily,
    fontWeight: FontWeight.w400,
  );
  static const TextStyle h2SemiBold = TextStyle(
    fontSize: 24,
    fontFamily: assistantFontFamily,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle h3Regular = TextStyle(
    fontSize: 16,
    fontFamily: assistantFontFamily,
    fontWeight: FontWeight.w400,
  );
  static const TextStyle h3SemiBold = TextStyle(
    fontSize: 16,
    fontFamily: assistantFontFamily,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle bodyRegular = TextStyle(
    fontSize: 14,
    fontFamily: assistantFontFamily,
    fontWeight: FontWeight.w400,
  );
  static const TextStyle bodySemiBold = TextStyle(
    fontSize: 14,
    fontFamily: assistantFontFamily,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle caption = TextStyle(
    fontSize: 12,
    fontFamily: assistantFontFamily,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle titleSemiBold = TextStyle(
    fontSize: 18,
    fontFamily: assistantFontFamily,
    fontWeight: FontWeight.w600,
  );
}

/// A copy of the host App's TPText (lib/util/tp_text.dart): Roboto for
/// Latin words and digits, PingFangTC for the rest, and plain texts follow the
/// page language outside a disabled PageTranslationScope.
class AssistantText extends StatelessWidget {
  /// The text to display.
  ///
  /// This will be null if a [textSpan] is provided instead.
  final String? data;

  /// The text to display as a [InlineSpan].
  ///
  /// This will be null if [data] is provided instead.
  final InlineSpan? textSpan;

  /// If non-null, the style to use for this text.
  ///
  /// If the style's "inherit" property is true, the style will be merged with
  /// the closest enclosing [DefaultTextStyle]. Otherwise, the style will
  /// replace the closest enclosing [DefaultTextStyle].
  final TextStyle? style;

  /// {@macro flutter.painting.textPainter.strutStyle}
  final StrutStyle? strutStyle;

  /// How the text should be aligned horizontally.
  final TextAlign? textAlign;

  /// The directionality of the text.
  ///
  /// This decides how [textAlign] values like [TextAlign.start] and
  /// [TextAlign.end] are interpreted.
  ///
  /// This is also used to disambiguate how to render bidirectional text. For
  /// example, if the [data] is an English phrase followed by a Hebrew phrase,
  /// in a [TextDirection.ltr] context the English phrase will be on the left
  /// and the Hebrew phrase to its right, while in a [TextDirection.rtl]
  /// context, the English phrase will be on the right and the Hebrew phrase on
  /// its left.
  ///
  /// Defaults to the ambient [Directionality], if any.
  final TextDirection? textDirection;

  /// Used to select a font when the same Unicode character can
  /// be rendered differently, depending on the locale.
  ///
  /// It's rarely necessary to set this property. By default its value
  /// is inherited from the enclosing app with `Localizations.localeOf(context)`.
  ///
  /// See [RenderParagraph.locale] for more information.
  final Locale? locale;

  /// Whether the text should break at soft line breaks.
  ///
  /// If false, the glyphs in the text will be positioned as if there was unlimited horizontal space.
  final bool? softWrap;

  /// How visual overflow should be handled.
  ///
  /// If this is null [TextStyle.overflow] will be used, otherwise the value
  /// from the nearest [DefaultTextStyle] ancestor will be used.
  final TextOverflow? overflow;

  /// {@macro flutter.painting.textPainter.textScaler}
  final TextScaler? textScaler;

  /// An optional maximum number of lines for the text to span, wrapping if necessary.
  /// If the text exceeds the given number of lines, it will be truncated according
  /// to [overflow].
  ///
  /// If this is 1, text will not wrap. Otherwise, text will be wrapped at the
  /// edge of the box.
  ///
  /// If this is null, but there is an ambient [DefaultTextStyle] that specifies
  /// an explicit number for its [DefaultTextStyle.maxLines], then the
  /// [DefaultTextStyle] value will take precedence. You can use a [RichText]
  /// widget directly to entirely override the [DefaultTextStyle].
  final int? maxLines;

  /// {@template flutter.widgets.Text.semanticsLabel}
  /// An alternative semantics label for this text.
  ///
  /// If present, the semantics of this widget will contain this value instead
  /// of the actual text. This will overwrite any of the semantics labels applied
  /// directly to the [TextSpan]s.
  ///
  /// This is useful for replacing abbreviations or shorthands with the full
  /// text value:
  ///
  /// ```dart
  /// const Text(r'$$', semanticsLabel: 'Double dollars')
  /// ```
  /// {@endtemplate}
  final String? semanticsLabel;

  /// {@macro flutter.painting.textPainter.textWidthBasis}
  final TextWidthBasis? textWidthBasis;

  /// {@macro dart.ui.textHeightBehavior}
  final TextHeightBehavior? textHeightBehavior;

  /// The color to use when painting the selection.
  ///
  /// This is ignored if [SelectionContainer.maybeOf] returns null
  /// in the [BuildContext] of the [Text] widget.
  ///
  /// If null, the ambient [DefaultSelectionStyle] is used (if any); failing
  /// that, the selection color defaults to [DefaultSelectionStyle.defaultColor]
  /// (semi-transparent grey).
  final Color? selectionColor;

  /// The color to use on text.
  final Color? color;

  /// A pointer has stopped contacting the screen, which is recognized as a tap
  /// of a primary button.
  ///
  /// This triggers on the up event, if the recognizer wins the arena with it
  /// or has previously won, immediately following [onTapUp].
  ///
  /// If this recognizer doesn't win the arena, [onTapCancel] is called instead.
  ///
  /// See also:
  ///
  ///  * [kPrimaryButton], the button this callback responds to.
  ///  * [onSecondaryTap], a similar callback but for a secondary button.
  ///  * [onTapUp], which has the same timing but with details.
  ///  * [GestureDetector.onTap], which exposes this callback.
  final GestureTapCallback? onTap;

  /// Creates a text widget.
  ///
  /// Recommend used with [AssistantTextStyle] and [AssistantColors] to make the App looks
  /// more cohesive, example:
  /// ```
  /// AssistantText(
  ///   'string',
  ///   style: AssistantTextStyle.bodyRegular,
  ///   color: AssistantColors.primary500,
  /// )
  /// ```
  ///
  /// If the [style] argument is null, the text will use the style from the
  /// closest enclosing [DefaultTextStyle].
  ///
  /// The [overflow] property's behavior is affected by the [softWrap] argument.
  /// If the [softWrap] is true or null, the glyph causing overflow, and those
  /// that follow, will not be rendered. Otherwise, it will be shown with the
  /// given overflow option.
  const AssistantText(
    this.data, {
    super.key,
    this.style,
    this.color,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
    this.onTap,
  }) : textSpan = null;

  const AssistantText.rich(
    this.textSpan, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
    this.color,
    this.onTap,
  }) : data = null;

  TapGestureRecognizer? get gestureRecognizer => switch (onTap) {
    GestureTapCallback onTap => TapGestureRecognizer()..onTap = onTap,
    null => null,
  };

  @override
  Widget build(BuildContext context) =>
      // Plain texts follow the page language (PageTranslation).
      PageTranslation.buildText(context, data, _build);

  Widget _build(String? text) {
    return Text.rich(
      switch (textSpan) {
        InlineSpan textSpan => AssistantTextSpan(
          children: [textSpan],
          recognizer: gestureRecognizer,
        ),
        null => AssistantTextSpan(text: text, recognizer: gestureRecognizer),
      },
      key: key,
      strutStyle: strutStyle,
      textAlign: textAlign,
      textDirection: textDirection,
      locale: locale,
      softWrap: softWrap,
      overflow: overflow,
      textScaler: textScaler,
      maxLines: maxLines,
      semanticsLabel: semanticsLabel,
      textWidthBasis: textWidthBasis,
      textHeightBehavior: textHeightBehavior,
      selectionColor: selectionColor,
      style: switch (style) {
        TextStyle style => switch (color) {
          Color color => style.copyWith(color: color),
          null => style,
        },
        null => TextStyle(color: color),
      },
    );
  }
}

/// A copy of the host App's TPTextSpan (lib/util/tp_text_span.dart).
class AssistantTextSpan extends TextSpan {
  /// The text contained in this span.
  ///
  /// If both [text] and [children] are non-null, the text will precede the
  /// children.
  ///
  /// This getter does not include the contents of its children.
  // Copied from TPTextSpan as it is.
  @override
  // ignore: overridden_fields
  final String? text;

  /// Additional spans to include as children.
  ///
  /// If both [text] and [children] are non-null, the text will precede the
  /// children.
  ///
  /// Modifying the list after the [TextSpan] has been created is not supported
  /// and may have unexpected results.
  ///
  /// The list must not contain any nulls.
  @override
  // ignore: overridden_fields
  final List<InlineSpan>? children;

  /// split text with words(english characters, digits and "_")
  static final RegExp _splitRegExp = RegExp(r'(?<=\W)(?=\w)|(?<=\w)(?=\W)');

  /// english characters, digits and "_"
  static final RegExp _wordCharacter = RegExp(r'\w');

  AssistantTextSpan({
    this.text,
    this.children,
    super.style,
    super.recognizer,
    super.mouseCursor,
    super.onEnter,
    super.onExit,
    super.semanticsLabel,
    super.locale,
    super.spellOut,
  }) : super(
         text: null,
         children: [
           ...?text
               ?.split(_splitRegExp)
               .map(
                 (text) => switch (text.contains(_wordCharacter)) {
                   true => TextSpan(
                     text: text,
                     style: switch (style) {
                       TextStyle style => style.copyWith(fontFamily: 'Roboto'),
                       null => const TextStyle(fontFamily: 'Roboto'),
                     },
                   ),
                   false => TextSpan(
                     text: text,
                     style: switch (style) {
                       TextStyle style => style.copyWith(
                         fontFamily: 'PingFangTC',
                       ),
                       null => const TextStyle(fontFamily: 'PingFangTC'),
                     },
                   ),
                 },
               ),
           ...?children,
         ],
       );
}
