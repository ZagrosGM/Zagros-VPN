#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <unistd.h>
#include <libgen.h>
#include <android/log.h>

#define TAG "ZagrosOpenVPNExec"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

int main(int argc, char **argv) {
    LOGI("minivpn starter invoked with argc=%d", argc);
    for (int i = 0; i < argc; i++) {
        LOGI("argv[%d] = %s", i, argv[i]);
    }

    void *handle = NULL;

    // 1. Resolve path of current executable to find sibling libopenvpn.so
    char exe_path[1024];
    memset(exe_path, 0, sizeof(exe_path));
    ssize_t len = readlink("/proc/self/exe", exe_path, sizeof(exe_path) - 1);
    if (len > 0) {
        exe_path[len] = '\0';
        char exe_copy[1024];
        strncpy(exe_copy, exe_path, sizeof(exe_copy) - 1);
        char *dir = dirname(exe_copy);
        char lib_path[1024];
        snprintf(lib_path, sizeof(lib_path), "%s/libopenvpn.so", dir);
        LOGI("Attempting dlopen on: %s", lib_path);
        handle = dlopen(lib_path, RTLD_NOW | RTLD_GLOBAL);
        if (handle) {
            LOGI("Successfully loaded libopenvpn.so from %s", lib_path);
        } else {
            LOGW("dlopen(%s) failed: %s", lib_path, dlerror());
        }
    }

    // 2. Fallback: try standard library loader search paths
    if (!handle) {
        LOGI("Attempting fallback dlopen on libopenvpn.so");
        handle = dlopen("libopenvpn.so", RTLD_NOW | RTLD_GLOBAL);
        if (handle) {
            LOGI("Successfully loaded libopenvpn.so from system/linker path");
        } else {
            LOGE("Fallback dlopen(libopenvpn.so) failed: %s", dlerror());
        }
    }

    if (!handle) {
        LOGE("FATAL: Cannot load libopenvpn.so anywhere!");
        fprintf(stderr, "FATAL: Cannot load libopenvpn.so\n");
        return 127;
    }

    int (*openvpn_main)(int, char **) = (int (*)(int, char **))dlsym(handle, "main");
    if (!openvpn_main) {
        openvpn_main = (int (*)(int, char **))dlsym(handle, "openvpn_main");
    }

    if (!openvpn_main) {
        LOGE("FATAL: Could not locate main/openvpn_main entry point in libopenvpn.so: %s", dlerror());
        fprintf(stderr, "FATAL: Entry point main not found in libopenvpn.so\n");
        return 126;
    }

    LOGI("Transferring execution to libopenvpn.so entry point...");
    return openvpn_main(argc, argv);
}
