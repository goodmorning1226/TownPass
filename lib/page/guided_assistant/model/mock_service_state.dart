import 'package:get/get.dart';

/// State of the mock service pages (water fee, library book), kept outside the
/// pages so that leaving a page and coming back keeps what was entered and the
/// guide can resume at the same step.
///
/// Demo only: nothing here is sent anywhere, and no real bill or reservation
/// is made.
class MockServiceState extends GetxService {
  // Water fee page.
  final waterFieldTapped = false.obs;
  final waterFocused = false.obs;
  final waterDigits = ''.obs;
  final waterQueried = false.obs;

  // Library book page.
  final libraryVolume = RxnString();
  final libraryBranch = RxnString();
  final libraryReserved = false.obs;

  static const waterDigitCount = 10;

  void resetWater() {
    waterFieldTapped.value = false;
    waterFocused.value = false;
    waterDigits.value = '';
    waterQueried.value = false;
  }

  void resetLibrary() {
    libraryVolume.value = null;
    libraryBranch.value = null;
    libraryReserved.value = false;
  }
}
