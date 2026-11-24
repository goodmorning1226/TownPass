# MainActivity starts the on-device assistant by reflection, so R8 must keep it.
-keep class com.example.townpass.OnDeviceAssistant { *; }
