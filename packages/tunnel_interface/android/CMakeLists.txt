cmake_minimum_required(VERSION 3.22.1)
project("hev-socks5-tunnel" C ASM)

set(HEV_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/src/main/cpp/hev-socks5-tunnel)

set(CMAKE_ASM_FLAGS "${CMAKE_ASM_FLAGS} -x assembler-with-cpp")

include_directories(
    ${HEV_ROOT}/src
    ${HEV_ROOT}/src/misc
    ${HEV_ROOT}/src/core/include
    ${HEV_ROOT}/src/core/src
    ${HEV_ROOT}/third-part/yaml/src
    ${HEV_ROOT}/third-part/yaml/include
    ${HEV_ROOT}/third-part/lwip/src/include
    ${HEV_ROOT}/third-part/lwip/src/ports/include
    ${HEV_ROOT}/third-part/hev-task-system/src
    ${HEV_ROOT}/third-part/hev-task-system/src/arch/arm
    ${HEV_ROOT}/third-part/hev-task-system/src/arch/x86
    ${HEV_ROOT}/third-part/hev-task-system/src/kern/core
    ${HEV_ROOT}/third-part/hev-task-system/src/kern/task
    ${HEV_ROOT}/third-part/hev-task-system/src/kern/sync
    ${HEV_ROOT}/third-part/hev-task-system/src/kern/time
    ${HEV_ROOT}/third-part/hev-task-system/src/kern/itc
    ${HEV_ROOT}/third-part/hev-task-system/src/kern/io
    ${HEV_ROOT}/third-part/hev-task-system/src/kern/aide
    ${HEV_ROOT}/third-part/hev-task-system/src/lib/io/basic
    ${HEV_ROOT}/third-part/hev-task-system/src/lib/io/socket
    ${HEV_ROOT}/third-part/hev-task-system/src/lib/io/pipe
    ${HEV_ROOT}/third-part/hev-task-system/src/lib/io/poll
    ${HEV_ROOT}/third-part/hev-task-system/src/lib/io/buffer
    ${HEV_ROOT}/third-part/hev-task-system/src/lib/list
    ${HEV_ROOT}/third-part/hev-task-system/src/lib/rbtree
    ${HEV_ROOT}/third-part/hev-task-system/src/lib/misc
    ${HEV_ROOT}/third-part/hev-task-system/src/lib/object
    ${HEV_ROOT}/third-part/hev-task-system/src/lib/dns
    ${HEV_ROOT}/third-part/hev-task-system/src/mem/base
    ${HEV_ROOT}/third-part/hev-task-system/src/mem/api
    ${HEV_ROOT}/third-part/hev-task-system/src/mem/simple
    ${HEV_ROOT}/third-part/hev-task-system/src/mem/slice
    ${HEV_ROOT}/third-part/hev-task-system/include
)

add_definitions(
    -DANDROID
    -DFD_SET_DEFINED
    -DSOCKLEN_T_DEFINED
    -DENABLE_LIBRARY
    -DENABLE_STACK_OVERFLOW_DETECTION
    -DENABLE_MEMALLOC_SLICE
    -DENABLE_IO_SPLICE_SYSCALL
    -DCONFIG_STACK_BACKEND=1
    -DCONFIG_STACK_OVERFLOW_DETECTION=1
    -DCONFIG_MEMALLOC_SLICE_ALIGN=16
    -DCONFIG_MEMALLOC_SLICE_MAX_SIZE=4096
    -DCONFIG_MEMALLOC_SLICE_MAX_COUNT=1000
    -DCONFIG_SCHED_CLOCK=0
    -DYAML_VERSION_MAJOR=0
    -DYAML_VERSION_MINOR=2
    -DYAML_VERSION_PATCH=5
    -DYAML_VERSION_STRING=\"0.2.5\"
    -DYAML_DECLARE_STATIC
    -DCOMMIT_ID=\"2.17.1\"
)

set(HEV_SOURCES
    ${HEV_ROOT}/src/hev-config.c
    ${HEV_ROOT}/src/hev-socks5-tunnel.c
    ${HEV_ROOT}/src/hev-main.c
    ${HEV_ROOT}/src/hev-jni.c
    ${HEV_ROOT}/src/hev-mapped-dns.c
    ${HEV_ROOT}/src/hev-socks5-session.c
    ${HEV_ROOT}/src/hev-socks5-session-tcp.c
    ${HEV_ROOT}/src/hev-socks5-session-udp.c
    ${HEV_ROOT}/src/hev-tunnel-linux.c
    ${HEV_ROOT}/src/misc/hev-ring-buffer.c
    ${HEV_ROOT}/src/misc/hev-logger.c
    ${HEV_ROOT}/src/misc/hev-exec.c
    ${HEV_ROOT}/src/misc/hev-utils.c
    ${HEV_ROOT}/src/core/src/hev-socks5-udp.c
    ${HEV_ROOT}/src/core/src/hev-socks5-authenticator.c
    ${HEV_ROOT}/src/core/src/hev-socks5-misc.c
    ${HEV_ROOT}/src/core/src/hev-socks5-logger.c
    ${HEV_ROOT}/src/core/src/hev-socks5.c
    ${HEV_ROOT}/src/core/src/hev-socks5-user.c
    ${HEV_ROOT}/src/core/src/hev-socks5-server.c
    ${HEV_ROOT}/src/core/src/hev-socks5-client-udp.c
    ${HEV_ROOT}/src/core/src/hev-socks5-tcp.c
    ${HEV_ROOT}/src/core/src/hev-socks5-client-tcp.c
    ${HEV_ROOT}/src/core/src/hev-socks5-client.c
    # YAML
    ${HEV_ROOT}/third-part/yaml/src/api.c
    ${HEV_ROOT}/third-part/yaml/src/dumper.c
    ${HEV_ROOT}/third-part/yaml/src/emitter.c
    ${HEV_ROOT}/third-part/yaml/src/loader.c
    ${HEV_ROOT}/third-part/yaml/src/parser.c
    ${HEV_ROOT}/third-part/yaml/src/reader.c
    ${HEV_ROOT}/third-part/yaml/src/scanner.c
    ${HEV_ROOT}/third-part/yaml/src/writer.c
    # LWIP
    ${HEV_ROOT}/third-part/lwip/src/core/altcp.c
    ${HEV_ROOT}/third-part/lwip/src/core/altcp_alloc.c
    ${HEV_ROOT}/third-part/lwip/src/core/altcp_tcp.c
    ${HEV_ROOT}/third-part/lwip/src/core/def.c
    ${HEV_ROOT}/third-part/lwip/src/core/dns.c
    ${HEV_ROOT}/third-part/lwip/src/core/inet_chksum.c
    ${HEV_ROOT}/third-part/lwip/src/core/init.c
    ${HEV_ROOT}/third-part/lwip/src/core/ip.c
    ${HEV_ROOT}/third-part/lwip/src/core/mem.c
    ${HEV_ROOT}/third-part/lwip/src/core/memp.c
    ${HEV_ROOT}/third-part/lwip/src/core/netif.c
    ${HEV_ROOT}/third-part/lwip/src/core/pbuf.c
    ${HEV_ROOT}/third-part/lwip/src/core/raw.c
    ${HEV_ROOT}/third-part/lwip/src/core/stats.c
    ${HEV_ROOT}/third-part/lwip/src/core/sys.c
    ${HEV_ROOT}/third-part/lwip/src/core/tcp.c
    ${HEV_ROOT}/third-part/lwip/src/core/tcp_in.c
    ${HEV_ROOT}/third-part/lwip/src/core/tcp_out.c
    ${HEV_ROOT}/third-part/lwip/src/core/timeouts.c
    ${HEV_ROOT}/third-part/lwip/src/core/udp.c
    ${HEV_ROOT}/third-part/lwip/src/core/ipv4/autoip.c
    ${HEV_ROOT}/third-part/lwip/src/core/ipv4/dhcp.c
    ${HEV_ROOT}/third-part/lwip/src/core/ipv4/etharp.c
    ${HEV_ROOT}/third-part/lwip/src/core/ipv4/icmp.c
    ${HEV_ROOT}/third-part/lwip/src/core/ipv4/igmp.c
    ${HEV_ROOT}/third-part/lwip/src/core/ipv4/ip4.c
    ${HEV_ROOT}/third-part/lwip/src/core/ipv4/ip4_addr.c
    ${HEV_ROOT}/third-part/lwip/src/core/ipv4/ip4_frag.c
    ${HEV_ROOT}/third-part/lwip/src/core/ipv6/dhcp6.c
    ${HEV_ROOT}/third-part/lwip/src/core/ipv6/ethip6.c
    ${HEV_ROOT}/third-part/lwip/src/core/ipv6/icmp6.c
    ${HEV_ROOT}/third-part/lwip/src/core/ipv6/inet6.c
    ${HEV_ROOT}/third-part/lwip/src/core/ipv6/ip6.c
    ${HEV_ROOT}/third-part/lwip/src/core/ipv6/ip6_addr.c
    ${HEV_ROOT}/third-part/lwip/src/core/ipv6/ip6_frag.c
    ${HEV_ROOT}/third-part/lwip/src/core/ipv6/mld6.c
    ${HEV_ROOT}/third-part/lwip/src/core/ipv6/nd6.c
    ${HEV_ROOT}/third-part/lwip/src/ports/unix/lib/sys_arch.c
    # Task system
    ${HEV_ROOT}/third-part/hev-task-system/src/kern/core/hev-task-system.c
    ${HEV_ROOT}/third-part/hev-task-system/src/kern/core/hev-task-system-schedule.c
    ${HEV_ROOT}/third-part/hev-task-system/src/kern/task/hev-task.c
    ${HEV_ROOT}/third-part/hev-task-system/src/kern/task/hev-task-call.c
    ${HEV_ROOT}/third-part/hev-task-system/src/kern/task/hev-task-executer.c
    ${HEV_ROOT}/third-part/hev-task-system/src/kern/task/hev-task-stack-heap.c
    ${HEV_ROOT}/third-part/hev-task-system/src/kern/task/hev-task-stack-mmap.c
    ${HEV_ROOT}/third-part/hev-task-system/src/kern/sync/hev-task-cond.c
    ${HEV_ROOT}/third-part/hev-task-system/src/kern/sync/hev-task-mutex.c
    ${HEV_ROOT}/third-part/hev-task-system/src/kern/time/hev-task-timer.c
    ${HEV_ROOT}/third-part/hev-task-system/src/kern/itc/hev-task-channel.c
    ${HEV_ROOT}/third-part/hev-task-system/src/kern/itc/hev-task-channel-select.c
    ${HEV_ROOT}/third-part/hev-task-system/src/kern/io/hev-task-io-reactor-epoll.c
    ${HEV_ROOT}/third-part/hev-task-system/src/kern/aide/hev-task-aide.c
    ${HEV_ROOT}/third-part/hev-task-system/src/lib/dns/hev-task-dns.c
    ${HEV_ROOT}/third-part/hev-task-system/src/lib/dns/hev-task-dns-proxy.c
    ${HEV_ROOT}/third-part/hev-task-system/src/lib/io/basic/hev-task-io.c
    ${HEV_ROOT}/third-part/hev-task-system/src/lib/io/buffer/hev-circular-buffer.c
    ${HEV_ROOT}/third-part/hev-task-system/src/lib/io/pipe/hev-task-io-pipe.c
    ${HEV_ROOT}/third-part/hev-task-system/src/lib/io/poll/hev-task-io-poll.c
    ${HEV_ROOT}/third-part/hev-task-system/src/lib/io/socket/hev-task-io-socket.c
    ${HEV_ROOT}/third-part/hev-task-system/src/lib/list/hev-list.c
    ${HEV_ROOT}/third-part/hev-task-system/src/lib/misc/hev-debugger.c
    ${HEV_ROOT}/third-part/hev-task-system/src/lib/misc/hev-task-stack-detector.c
    ${HEV_ROOT}/third-part/hev-task-system/src/lib/object/hev-object.c
    ${HEV_ROOT}/third-part/hev-task-system/src/lib/object/hev-object-atomic.c
    ${HEV_ROOT}/third-part/hev-task-system/src/lib/rbtree/hev-rbtree.c
    ${HEV_ROOT}/third-part/hev-task-system/src/lib/rbtree/hev-rbtree-cached.c
    ${HEV_ROOT}/third-part/hev-task-system/src/mem/api/hev-memory-allocator-api.c
    ${HEV_ROOT}/third-part/hev-task-system/src/mem/base/hev-memory-allocator.c
    ${HEV_ROOT}/third-part/hev-task-system/src/mem/simple/hev-memory-allocator-simple.c
    ${HEV_ROOT}/third-part/hev-task-system/src/mem/slice/hev-memory-allocator-slice.c
)

if (ANDROID_ABI STREQUAL "arm64-v8a")
    list(APPEND HEV_SOURCES ${HEV_ROOT}/third-part/hev-task-system/src/arch/arm/hev-task-execute-aarch64.s)
elseif (ANDROID_ABI STREQUAL "armeabi-v7a")
    list(APPEND HEV_SOURCES ${HEV_ROOT}/third-part/hev-task-system/src/arch/arm/hev-task-execute-arm.s)
elseif (ANDROID_ABI STREQUAL "x86_64")
    list(APPEND HEV_SOURCES ${HEV_ROOT}/third-part/hev-task-system/src/arch/x86/hev-task-execute-x86_64.s)
elseif (ANDROID_ABI STREQUAL "x86")
    list(APPEND HEV_SOURCES ${HEV_ROOT}/third-part/hev-task-system/src/arch/x86/hev-task-execute-x86.s)
endif()

add_library(hev-socks5-tunnel SHARED ${HEV_SOURCES})
target_link_libraries(hev-socks5-tunnel log)

add_executable(libovpnexec.so src/main/cpp/minivpn.c)
target_link_libraries(libovpnexec.so dl log -fPIE -pie)

