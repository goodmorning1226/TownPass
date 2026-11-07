import 'package:get/get.dart';
import 'package:town_pass/service/page_translation.dart';

/// Page language (PageTranslation): the App's pages are shown in the chosen
/// language; the assistant's navigation in another language also switches it.
class LanguageViewController extends GetxController {
  List<String> get languageList => PageTranslation.languages.keys.toList();

  int get currentIndex => languageList
      .indexOf(PageTranslation.instance.language.value)
      .clamp(0, languageList.length - 1);

  void onIndexChange(int index) {
    if (index < 0 || index >= languageList.length) return;
    PageTranslation.instance.setLanguage(languageList[index]);
  }
}
