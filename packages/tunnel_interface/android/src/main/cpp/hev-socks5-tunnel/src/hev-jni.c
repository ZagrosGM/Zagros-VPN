/*
 ============================================================================
 Name        : hev-jni.c
 Author      : hev <r@hev.cc>
 Copyright   : Copyright (c) 2019 - 2023 hev
 Description : Jave Native Interface
 ============================================================================
 */

#ifdef ANDROID

#include <jni.h>
#include <pthread.h>
#include <stdatomic.h>

#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/un.h>

#include "hev-main.h"

#include "hev-jni.h"

/* clang-format off */
#ifndef PKGNAME
#define PKGNAME hev/htproxy
#endif
#ifndef CLSNAME
#define CLSNAME TProxyService
#endif
/* clang-format on */

#define STR(s) STR_ARG (s)
#define STR_ARG(c) #c
#define N_ELEMENTS(arr) (sizeof (arr) / sizeof ((arr)[0]))

typedef struct _ThreadData ThreadData;

struct _ThreadData
{
    char *path;
    int fd;
};

static atomic_int is_running;
static int thread_joinable;
static JavaVM *java_vm;
static pthread_t work_thread;
static pthread_mutex_t mutex;
static pthread_key_t current_jni_env;

static jboolean native_start_service (JNIEnv *env, jobject thiz,
                                      jstring conig_path, jint fd);
static jboolean native_stop_service (JNIEnv *env, jobject thiz);
static jboolean native_is_running (JNIEnv *env, jobject thiz);
static jlongArray native_get_stats (JNIEnv *env, jobject thiz);
static jobject native_create_unix_listen (JNIEnv *env, jclass thiz,
                                          jstring path);
static jboolean native_close_unix_listen (JNIEnv *env, jclass thiz,
                                          jobject jfd, jstring path);
static jint native_protect_probe (JNIEnv *env, jclass thiz, jstring jname);

static JNINativeMethod native_methods[] = {
    { "TProxyStartService", "(Ljava/lang/String;I)Z",
      (void *)native_start_service },
    { "TProxyStopService", "()Z", (void *)native_stop_service },
    { "TProxyIsRunning", "()Z", (void *)native_is_running },
    { "TProxyGetStats", "()[J", (void *)native_get_stats },
    { "TProxyCreateUnixListen", "(Ljava/lang/String;)Ljava/io/FileDescriptor;",
      (void *)native_create_unix_listen },
    { "TProxyCloseUnixListen",
      "(Ljava/io/FileDescriptor;Ljava/lang/String;)Z",
      (void *)native_close_unix_listen },
    { "TProxyProtectProbe", "(Ljava/lang/String;)I",
      (void *)native_protect_probe },
};

/* End-to-end protect-channel self-test with a plain POSIX client: dial the
 * abstract name, send the PING command byte (0), expect ack 1. Returns 0 on
 * success or -errno. The java.net LocalSocket stack is bypassed entirely —
 * on one tested device it failed with "socket not created". */
static jint
native_protect_probe (JNIEnv *env, jclass thiz, jstring jname)
{
    const char *name;
    struct sockaddr_un addr;
    socklen_t len;
    char cmd = 0, ack = 0;
    int fd, e, ret;
    ssize_t n;

    (void)thiz;
    name = (*env)->GetStringUTFChars (env, jname, NULL);
    if (!name)
        return -22; /* EINVAL */
    fd = socket (AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        e = errno;
        (*env)->ReleaseStringUTFChars (env, jname, name);
        return -e;
    }
    memset (&addr, 0, sizeof (addr));
    addr.sun_family = AF_UNIX;
    addr.sun_path[0] = '\0';
    strncpy (addr.sun_path + 1, name, sizeof (addr.sun_path) - 2);
    /* Exact abstract length: family(2) + NUL(1) + name — byte-identical to
     * Android's abstract bind. */
    len = (socklen_t)(2 + 1 + strlen (name));
    ret = connect (fd, (struct sockaddr *)&addr, len);
    e = errno;
    if (ret < 0) {
        close (fd);
        (*env)->ReleaseStringUTFChars (env, jname, name);
        return -e;
    }
    n = send (fd, &cmd, 1, 0);
    if (n != 1) {
        e = errno ? errno : EIO;
        close (fd);
        (*env)->ReleaseStringUTFChars (env, jname, name);
        return -e;
    }
    n = recv (fd, &ack, 1, 0);
    e = errno;
    close (fd);
    (*env)->ReleaseStringUTFChars (env, jname, name);
    if (n != 1)
        return -(e ? e : EIO);
    return ack == 1 ? 0 : -71; /* EPROTO: unexpected ack */
}

static void
detach_current_thread (void *env)
{
    (*java_vm)->DetachCurrentThread (java_vm);
}

/* Binds a REAL filesystem unix listening socket (android.net.LocalServerSocket
 * only supports the abstract namespace) and wraps it in a FileDescriptor so
 * LocalServerSocket(fd) can accept() on it. Used by the out-of-process
 * protect server: the exec'd sing-box child dials this path to hand us its
 * outbound fds for VpnService.protect(). */
static jobject
native_create_unix_listen (JNIEnv *env, jclass thiz, jstring path)
{
    const char *path_utf8;
    struct sockaddr_un addr;
    jclass fd_class;
    jmethodID ctor;
    jobject jfd;
    int fd, ret;

    (void)thiz;
    path_utf8 = (*env)->GetStringUTFChars (env, path, NULL);
    if (!path_utf8)
        return NULL;
    fd = socket (AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        (*env)->ReleaseStringUTFChars (env, path, path_utf8);
        return NULL;
    }
    unlink (path_utf8);
    memset (&addr, 0, sizeof (addr));
    addr.sun_family = AF_UNIX;
    strncpy (addr.sun_path, path_utf8, sizeof (addr.sun_path) - 1);
    ret = bind (fd, (struct sockaddr *)&addr, sizeof (addr));
    (*env)->ReleaseStringUTFChars (env, path, path_utf8);
    if (ret < 0) {
        close (fd);
        return NULL;
    }
    if (listen (fd, 50) < 0) {
        close (fd);
        return NULL;
    }
    fd_class = (*env)->FindClass (env, "java/io/FileDescriptor");
    if (!fd_class) {
        close (fd);
        return NULL;
    }
    ctor = (*env)->GetMethodID (env, fd_class, "<init>", "(I)V");
    if (!ctor) {
        close (fd);
        return NULL;
    }
    jfd = (*env)->NewObject (env, fd_class, ctor, fd);
    return jfd;
}

/* LocalServerSocket(FileDescriptor) documents close() as a no-op — close the
 * underlying fd ourselves and unlink the socket node. */
static jboolean
native_close_unix_listen (JNIEnv *env, jclass thiz, jobject jfd, jstring path)
{
    jclass fd_class;
    jfieldID fd_field;
    const char *path_utf8;
    int fd;

    (void)thiz;
    fd_class = (*env)->GetObjectClass (env, jfd);
    if (!fd_class)
        return JNI_FALSE;
    fd_field = (*env)->GetFieldID (env, fd_class, "fd", "I");
    if (!fd_field)
        return JNI_FALSE;
    fd = (*env)->GetIntField (env, jfd, fd_field);
    if (fd >= 0)
        close (fd);
    if (path) {
        path_utf8 = (*env)->GetStringUTFChars (env, path, NULL);
        if (path_utf8) {
            unlink (path_utf8);
            (*env)->ReleaseStringUTFChars (env, path, path_utf8);
        }
    }
    return JNI_TRUE;
}

jint
JNI_OnLoad (JavaVM *vm, void *reserved)
{
    JNIEnv *env = NULL;
    jclass klass;
    jint res;

    java_vm = vm;
    res = (*vm)->GetEnv (vm, (void **)&env, JNI_VERSION_1_4);
    if (res != JNI_OK)
        return JNI_ERR;

    klass = (*env)->FindClass (env, STR (PKGNAME) "/" STR (CLSNAME));
    if (!klass)
        return JNI_ERR;
    res = (*env)->RegisterNatives (env, klass, native_methods,
                                   N_ELEMENTS (native_methods));
    (*env)->DeleteLocalRef (env, klass);
    if (res < 0)
        return JNI_ERR;

    pthread_key_create (&current_jni_env, detach_current_thread);
    pthread_mutex_init (&mutex, NULL);

    return JNI_VERSION_1_4;
}

static void *
thread_handler (void *data)
{
    ThreadData *tdata = data;

    hev_socks5_tunnel_main (tdata->path, tdata->fd);

    atomic_store_explicit (&is_running, 0, memory_order_release);

    free (tdata->path);
    free (tdata);

    return NULL;
}

static jboolean
native_start_service (JNIEnv *env, jobject thiz, jstring config_path, jint fd)
{
    const jbyte *bytes;
    ThreadData *tdata;
    int res;
    jboolean result = JNI_FALSE;

    pthread_mutex_lock (&mutex);

    if (atomic_load_explicit (&is_running, memory_order_acquire))
        goto exit;

    if (thread_joinable) {
        pthread_join (work_thread, NULL);
        thread_joinable = 0;
    }

    tdata = malloc (sizeof (ThreadData));
    if (!tdata)
        goto exit;
    tdata->fd = fd;

    bytes = (const jbyte *)(*env)->GetStringUTFChars (env, config_path, NULL);
    if (!bytes) {
        free (tdata);
        goto exit;
    }
    tdata->path = strdup ((const char *)bytes);
    (*env)->ReleaseStringUTFChars (env, config_path, (const char *)bytes);
    if (!tdata->path) {
        free (tdata);
        goto exit;
    }

    atomic_store_explicit (&is_running, 1, memory_order_release);
    res = pthread_create (&work_thread, NULL, thread_handler, tdata);
    if (res != 0) {
        atomic_store_explicit (&is_running, 0, memory_order_release);
        free (tdata->path);
        free (tdata);
        goto exit;
    }

    thread_joinable = 1;
    result = JNI_TRUE;
exit:
    pthread_mutex_unlock (&mutex);
    return result;
}

static jboolean
native_stop_service (JNIEnv *env, jobject thiz)
{
    int res = 0;

    pthread_mutex_lock (&mutex);

    if (!thread_joinable)
        goto exit;

    if (atomic_load_explicit (&is_running, memory_order_acquire))
        hev_socks5_tunnel_quit ();
    res = pthread_join (work_thread, NULL);

    thread_joinable = 0;
    atomic_store_explicit (&is_running, 0, memory_order_release);
exit:
    pthread_mutex_unlock (&mutex);
    return res == 0 ? JNI_TRUE : JNI_FALSE;
}

static jboolean
native_is_running (JNIEnv *env, jobject thiz)
{
    return atomic_load_explicit (&is_running, memory_order_acquire) ? JNI_TRUE :
                                                                      JNI_FALSE;
}

static jlongArray
native_get_stats (JNIEnv *env, jobject thiz)
{
    size_t tx_packets, rx_packets, tx_bytes, rx_bytes;
    jlongArray res;
    jlong array[4];

    hev_socks5_tunnel_stats (&tx_packets, &tx_bytes, &rx_packets, &rx_bytes);
    array[0] = tx_packets;
    array[1] = tx_bytes;
    array[2] = rx_packets;
    array[3] = rx_bytes;

    res = (*env)->NewLongArray (env, 4);
    (*env)->SetLongArrayRegion (env, res, 0, 4, array);

    return res;
}

#endif /* ANDROID */
