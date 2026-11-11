use std::path::{Path, PathBuf};

fn main() {
    // Vendored libghostty-vt, one directory per platform, put there by
    // vendor/build-vt.sh from the release it pins: the macOS slice from the
    // official XCFramework, the others built from the release's source
    // tarball with Zig (Windows on Windows, against the MSVC toolchain the
    // Rust links with, under Git Bash).
    //
    // `KEEP_GHOSTTY_VT_DIR` names the directory outright, for a build that
    // keeps the library somewhere else.
    let os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    let arch = std::env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_default();
    println!("cargo:rerun-if-env-changed=KEEP_GHOSTTY_VT_DIR");
    let vendor = match std::env::var("KEEP_GHOSTTY_VT_DIR") {
        Ok(dir) => PathBuf::from(dir),
        Err(_) => {
            let slice = match os.as_str() {
                "linux" => format!("libghostty-vt-linux-{arch}"),
                "windows" => format!("libghostty-vt-windows-{arch}"),
                _ => "libghostty-vt".to_string(),
            };
            // Read as the script runs, not as it was compiled: a worktree that
            // shares this `target/` gets the same script, built once, and the
            // path compiled into it is the other checkout's.
            let manifest = std::env::var_os("CARGO_MANIFEST_DIR").unwrap_or_default();
            PathBuf::from(manifest).join("../../vendor").join(slice)
        }
    };
    let vendor = vendor
        .canonicalize()
        .unwrap_or_else(|_| panic!("{} missing - run vendor/build-vt.sh", vendor.display()));

    // Zig names the static library for the platform: `libghostty-vt.a`, or
    // `ghostty-vt-static.lib` beside the import library of the DLL.
    let (lib, file) = if os == "windows" {
        ("ghostty-vt-static", "ghostty-vt-static.lib")
    } else {
        ("ghostty-vt", "libghostty-vt.a")
    };
    println!("cargo:rustc-link-search=native={}", vendor.display());
    println!("cargo:rustc-link-lib=static={lib}");
    if os == "windows" {
        // The Zig standard library calls into these directly.
        println!("cargo:rustc-link-lib=ntdll");
        println!("cargo:rustc-link-lib=kernel32");
    }
    println!("cargo:include={}", vendor.join("include").display());
    println!("cargo:rerun-if-changed={}", vendor.join(file).display());

    check_abi(&vendor.join("include"));
}

/// Compile `src/abi.rs`, as C `_Static_assert`s, against the headers of the
/// library being linked: the bindings are written by hand, and a value or a
/// layout that moved upstream would otherwise go on compiling and corrupt
/// every call that uses it. Nothing is linked; a mismatch fails the build
/// with the C name and the value the Rust side expects.
fn check_abi(include: &Path) {
    let manifest = PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").unwrap_or_default());
    let table = manifest.join("src/abi.rs");
    println!("cargo:rerun-if-changed={}", table.display());
    let text = std::fs::read_to_string(&table).expect("src/abi.rs");
    let mut c = String::from("#include <stddef.h>\n#include <ghostty/vt.h>\n");
    let mut checks = 0;
    for line in text.lines().map(str::trim) {
        let Some(args) = line.strip_suffix(");") else { continue };
        let assert = if let Some(args) = args.strip_prefix("abi!(") {
            // abi!(<rust>, <value>, "<C name>")
            let (rest, name) = args.rsplit_once(", ").expect(line);
            let (_, value) = rest.rsplit_once(", ").expect(line);
            let name = name.trim_matches('"');
            format!("_Static_assert((long long)({name}) == ({value}), \"keep-vt abi: {name} is not {value}\");")
        } else if let Some(args) = args.strip_prefix("abi_size!(") {
            // abi_size!(<rust type>, <size>, "<C type>")
            let (rest, name) = args.rsplit_once(", ").expect(line);
            let (_, size) = rest.rsplit_once(", ").expect(line);
            let name = name.trim_matches('"');
            format!("_Static_assert(sizeof({name}) == {size}, \"keep-vt abi: sizeof({name}) is not {size}\");")
        } else if let Some(args) = args.strip_prefix("abi_offset!(") {
            // abi_offset!(<rust type>, <field>, <offset>, "<C type>", "<C field>")
            let parts: Vec<&str> = args.rsplitn(4, ", ").collect();
            let (field, name, offset) = (parts[0].trim_matches('"'), parts[1].trim_matches('"'), parts[2]);
            format!(
                "_Static_assert(offsetof({name}, {field}) == {offset}, \"keep-vt abi: {name}.{field} is not at {offset}\");"
            )
        } else {
            continue;
        };
        c.push_str(&assert);
        c.push('\n');
        checks += 1;
    }
    assert!(checks > 0, "src/abi.rs: no abi checks found");
    let out = PathBuf::from(std::env::var_os("OUT_DIR").expect("OUT_DIR")).join("abi_check.c");
    std::fs::write(&out, c).expect("write abi_check.c");
    cc::Build::new()
        .file(&out)
        .include(include)
        .std("c11")
        .cargo_metadata(false)
        .warnings(false)
        .compile_intermediates();
}
