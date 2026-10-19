// Builds the helper's online transport stack (ADR 0009) from the same pinned sources under ext/ that
// portable/friends/deps/datachannel.mk compiles for the Objective-C helper: libdatachannel 0.24.6 (data channels only,
// Mbed TLS backend), its bundled libjuice and usrsctp, plog (headers) and Mbed TLS 3.6.7. Same source lists and
// configuration macros, except that Mbed TLS keeps only what DTLS and the host connection use, the C libraries carry
// no unwind tables and libdatachannel no logging (ADR 0015 § 12's sizes); the per-platform macros below are what
// upstream's CMake checks find on each platform, which datachannel.mk only states for macOS. No CMake (ADR 0015 § 9):
// cc and the target's own C and C++ compilers.
//
// SZFRIENDS_DATACHANNEL_NO_NATIVE=1 skips the native build entirely, for `cargo check` of targets whose compilers
// this machine does not have (friends-core-rs-cross-check checks Windows MSVC from a Mac). Nothing links then.
// SZFRIENDS_EXT_DIR names the directory holding libdatachannel/, libjuice/, ... when it is not an ancestor's ext/
// (the VM test runs copy it beside the workspace).

use std::env;
use std::fs;
use std::path::{Path, PathBuf};

struct Target {
    os: String,
    msvc: bool,
}

impl Target {
    fn windows(&self) -> bool {
        self.os == "windows"
    }
}

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=SZFRIENDS_DATACHANNEL_NO_NATIVE");
    println!("cargo:rerun-if-env-changed=SZFRIENDS_EXT_DIR");
    println!("cargo:rerun-if-env-changed=SZFRIENDS_DATACHANNEL_LOGGING");
    if env::var_os("SZFRIENDS_DATACHANNEL_NO_NATIVE").is_some_and(|v| v == "1") {
        return;
    }
    let target = Target {
        os: env::var("CARGO_CFG_TARGET_OS").unwrap_or_default(),
        msvc: env::var("CARGO_CFG_TARGET_ENV").is_ok_and(|v| v == "msvc"),
    };
    // The app floors (ADR 0015): macOS 12 like the helper, iOS 15. Set only when the caller has not chosen one, so
    // a host app's own floor wins; the scripts in tools/ export the same values so rustc links for the same floor.
    let floors = [("macos", "MACOSX_DEPLOYMENT_TARGET", "12.0"), ("ios", "IPHONEOS_DEPLOYMENT_TARGET", "15.0")];
    for (os, var, floor) in floors {
        if target.os == os && env::var_os(var).is_none() {
            // SAFETY: build scripts are single-threaded; cc reads the variable below.
            unsafe { env::set_var(var, floor) };
        }
    }
    let ext = ext_dir();
    for name in ["libdatachannel", "libjuice", "usrsctp", "plog", "mbedtls"] {
        println!("cargo:rerun-if-changed={}", ext.join(name).display());
    }
    build_mbedtls(&target, &ext.join("mbedtls"));
    build_usrsctp(&target, &ext.join("usrsctp/usrsctplib"));
    build_juice(&target, &ext.join("libjuice"));
    build_datachannel(&target, &ext);
    build_tls(&target, &ext.join("mbedtls"));
    link_system(&target);
    println!("cargo:include={}", ext.join("libdatachannel/include").display());
}

fn ext_dir() -> PathBuf {
    if let Some(dir) = env::var_os("SZFRIENDS_EXT_DIR") {
        return PathBuf::from(dir);
    }
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    manifest
        .ancestors()
        .map(|dir| dir.join("ext"))
        .find(|ext| ext.join("libdatachannel/include/rtc/rtc.h").is_file())
        .expect("ext/libdatachannel not found above the crate; set SZFRIENDS_EXT_DIR")
}

// The .c or .cpp files directly in `dir`, sorted, so the archive's member order is stable.
fn sources(dir: &Path, extension: &str) -> Vec<PathBuf> {
    let mut files: Vec<PathBuf> = fs::read_dir(dir)
        .unwrap_or_else(|e| panic!("{}: {e}", dir.display()))
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|path| path.extension().is_some_and(|ext| ext == extension))
        .collect();
    files.sort();
    files
}

// Flags shared by every library: -O2 in every profile, as datachannel.mk builds the helper's copy (upstream's
// Release flags), so both run the same optimised code whatever the Rust profile's opt-level, except on phones, where
// -Oz keeps the stack as small as it goes for ADR 0015 § 12's size budget (a phone's transfers are bounded by its
// radio, not by this code); hidden visibility (as in
// datachannel.mk, so a linker's dead stripping removes what the core never calls and nothing of the stack is exported
// from a cdylib); and no compiler warnings in cargo's output, since the sources are upstream's unmodified.
fn base(target: &Target) -> cc::Build {
    let mut build = cc::Build::new();
    let phone = matches!(target.os.as_str(), "android" | "ios");
    build.opt_level_str(if phone { "z" } else { "2" }).warnings(false).extra_warnings(false).cargo_warnings(false);
    if target.msvc {
        build.flag("/wd4005").define("_CRT_SECURE_NO_WARNINGS", None).define("_WINSOCK_DEPRECATED_NO_WARNINGS", None);
    } else {
        build.flag("-fvisibility=hidden");
    }
    build
}

// The C libraries without unwind tables (ADR 0015 § 12's sizes: they were a sixth of the stack on Android). Nothing
// unwinds through C: libdatachannel catches its exceptions in the callbacks the C code calls.
fn c_base(target: &Target) -> cc::Build {
    let mut build = base(target);
    if !target.msvc {
        build.flag("-fno-asynchronous-unwind-tables").flag("-fno-unwind-tables");
    }
    build
}

// Everything that includes Mbed TLS's headers (the library, libdatachannel, src/tls.c) reads the same trimmed
// configuration, src/mbedtls_trim.h, so the structures agree.
fn mbedtls_config(build: &mut cc::Build) {
    let here = PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    println!("cargo:rerun-if-changed=src/mbedtls_trim.h");
    build.include(here.join("src")).define("MBEDTLS_USER_CONFIG_FILE", "\"mbedtls_trim.h\"");
}

// Mbed TLS 3.6.7: default configuration plus MBEDTLS_SSL_DTLS_SRTP (datachannel.mk explains why), trimmed to what
// DTLS and the host connection use (src/mbedtls_trim.h). Upstream's three
// libraries in one archive; NDEBUG stays undefined, as in upstream's Release build.
fn build_mbedtls(target: &Target, dir: &Path) {
    let mut build = c_base(target);
    if !target.msvc {
        build.std("c99");
    }
    build.include(dir.join("include")).include(dir.join("library")).define("MBEDTLS_SSL_DTLS_SRTP", None);
    mbedtls_config(&mut build);
    for file in sources(&dir.join("library"), "c") {
        if file.file_name().is_some_and(|name| name != "ecp_curves_new.c") {
            build.file(file);
        }
    }
    build.compile("szfdc_mbedtls");
}

// usrsctp over libdatachannel's own transport (AF_CONN) only: no INET or INET6. The HAVE_* macros are the results of
// usrsctp's CMake checks on each platform (datachannel.mk lists the macOS set).
fn build_usrsctp(target: &Target, dir: &Path) {
    let mut build = c_base(target);
    if !target.msvc {
        build.std("c99").flag_if_supported("-Wno-address-of-packed-member");
    }
    build.include(dir).define("NDEBUG", None);
    for name in ["__Userspace__", "SCTP_SIMPLE_ALLOCATOR", "SCTP_PROCESS_LEVEL_LOCKS", "SCTP_DEBUG"] {
        build.define(name, None);
    }
    let checks: &[&str] = match target.os.as_str() {
        "macos" | "ios" => &[
            "__APPLE_USE_RFC_2292",
            "HAVE_SYS_QUEUE_H",
            "HAVE_NETINET_IP_ICMP_H",
            "HAVE_NET_ROUTE_H",
            "HAVE_STDATOMIC_H",
            "HAVE_SA_LEN",
            "HAVE_SIN_LEN",
            "HAVE_SIN6_LEN",
            "HAVE_SCONN_LEN",
        ],
        // CMake's system name is "Linux" for glibc and "Android" for Bionic: only the former adds _GNU_SOURCE.
        "linux" => &[
            "_GNU_SOURCE",
            "HAVE_SYS_QUEUE_H",
            "HAVE_LINUX_IF_ADDR_H",
            "HAVE_LINUX_RTNETLINK_H",
            "HAVE_NETINET_IP_ICMP_H",
            "HAVE_STDATOMIC_H",
        ],
        "android" => &[
            "HAVE_SYS_QUEUE_H",
            "HAVE_LINUX_IF_ADDR_H",
            "HAVE_LINUX_RTNETLINK_H",
            "HAVE_NETINET_IP_ICMP_H",
            "HAVE_STDATOMIC_H",
        ],
        _ => &[],
    };
    for name in checks {
        build.define(name, None);
    }
    for sub in [".", "netinet", "netinet6"] {
        build.files(sources(&dir.join(sub), "c"));
    }
    build.compile("szfdc_usrsctp");
}

// libjuice 1.7.4: RELEASE=1 (upstream's Release configuration), built-in hashes (USE_NETTLE=0).
fn build_juice(target: &Target, dir: &Path) {
    let mut build = c_base(target);
    if target.msvc {
        build.flag("/std:c11");
    } else {
        build.std("gnu11");
    }
    build
        .include(dir.join("include"))
        .include(dir.join("include/juice"))
        .include(dir.join("src"))
        .define("NDEBUG", None)
        .define("JUICE_STATIC", None)
        .define("JUICE_EXPORTS", None)
        .define("RELEASE", "1")
        .define("USE_NETTLE", "0");
    build.files(sources(&dir.join("src"), "c"));
    build.compile("szfdc_juice");
}

// libdatachannel 0.24.6, C++17, data channels only: no media (so no libsrtp) and no WebSocket.
fn build_datachannel(target: &Target, ext: &Path) {
    let dir = ext.join("libdatachannel");
    let mut build = base(target);
    build.cpp(true).std(if target.msvc { "c++17" } else { "gnu++17" });
    build
        .include(dir.join("include"))
        .include(dir.join("include/rtc"))
        .include(dir.join("src"))
        .include(ext.join("usrsctp/usrsctplib"))
        .include(ext.join("plog/include"))
        .include(ext.join("libjuice/include"))
        .include(ext.join("mbedtls/include"));
    let defines: &[(&str, &str)] = &[
        ("NDEBUG", "1"),
        ("RTC_STATIC", "1"),
        ("RTC_ENABLE_MEDIA", "0"),
        ("RTC_ENABLE_WEBSOCKET", "0"),
        ("RTC_EXPORTS", "1"),
        ("USE_MBEDTLS", "1"),
        ("USE_NICE", "0"),
        ("RTC_SYSTEM_JUICE", "0"),
        ("JUICE_STATIC", "1"),
        ("MBEDTLS_SSL_DTLS_SRTP", "1"),
    ];
    for (name, value) in defines {
        build.define(name, *value);
    }
    mbedtls_config(&mut build);
    // No logging compiled in: nothing reads the stack's log, and each message is code at its call site.
    // SZFRIENDS_DATACHANNEL_LOGGING=1 keeps it, for log_to_stderr while debugging.
    if env::var_os("SZFRIENDS_DATACHANNEL_LOGGING").is_none_or(|v| v != "1") {
        build.define("PLOG_DISABLE_LOGGING", "1");
    }
    if target.windows() {
        build.define("WIN32_LEAN_AND_MEAN", None);
        if target.msvc {
            build.define("NOMINMAX", None).flag("/bigobj").flag("/EHsc");
        }
    }
    // The C++ runtime: libc++ on Apple platforms, the NDK's static libc++ on Android (an app's one .so carries it, as
    // Tauri's does), libstdc++ on glibc Linux, the MSVC runtime on Windows.
    if target.os == "android" {
        build.cpp_link_stdlib(Some("c++_static"));
    }
    build.files(sources(&dir.join("src"), "cpp"));
    build.files(sources(&dir.join("src/impl"), "cpp"));
    build.compile("szfdc_datachannel");

    // src/layout.c: rtc.h's structures as this target's C compiler lays them out, for src/layout.rs.
    let mut layout = c_base(target);
    layout.include(dir.join("include")).define("RTC_STATIC", None);
    layout.define("RTC_ENABLE_MEDIA", "0").define("RTC_ENABLE_WEBSOCKET", "0").file("src/layout.c");
    println!("cargo:rerun-if-changed=src/layout.c");
    layout.compile("szfdc_layout");
}

// src/tls.c: the host connection's TLS client on the same Mbed TLS, and the system's certificate check where the system
// keeps its own (crypt32 on Windows, Security on Apple systems).
fn build_tls(target: &Target, dir: &Path) {
    let mut build = c_base(target);
    build.include(dir.join("include")).define("MBEDTLS_SSL_DTLS_SRTP", None).file("src/tls.c");
    mbedtls_config(&mut build);
    println!("cargo:rerun-if-changed=src/tls.c");
    build.compile("szfdc_tls");
    if matches!(target.os.as_str(), "macos" | "ios") {
        println!("cargo:rustc-link-lib=framework=Security");
        println!("cargo:rustc-link-lib=framework=CoreFoundation");
    }
}

fn link_system(target: &Target) {
    let libs: &[&str] = match target.os.as_str() {
        "windows" => &["ws2_32", "iphlpapi", "bcrypt", "crypt32"],
        "android" => &["c++abi"],
        "linux" => &["pthread"],
        _ => &[],
    };
    for lib in libs {
        println!("cargo:rustc-link-lib={lib}");
    }
}
