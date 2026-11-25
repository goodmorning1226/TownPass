// Support code for WhisperServer.framework (TownPass on-device assistant, iOS).
// whisper-server's main() is exported as townpass_whisper_server via a linker alias.
// iOS apps cannot run a shell: the ffmpeg/speak helpers (unused here) just fail.
extern "C" int townpass_system_unavailable(const char *) { return -1; }
