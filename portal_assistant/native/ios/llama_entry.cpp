// Entry point exported by LlamaServer.framework (TownPass on-device assistant, iOS).
int llama_server(int argc, char ** argv);
extern "C" __attribute__((visibility("default"))) int townpass_llama_server(int argc, char ** argv) {
    return llama_server(argc, argv);
}
