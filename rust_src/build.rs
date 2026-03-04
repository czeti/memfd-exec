//! Build script for integrating hand-written assembly objects into a Rust executable.
//!
//! This build script is invoked by Cargo when building the crate. Its purpose is to:
//!   1. Locate the `ar` archiver (part of binutils) which is required to create static libraries.
//!   2. For each predefined assembly object file (e.g., `_start.o`, `executor.o`, …) located in
//!      `../build/`, create a static library `lib<name>.a` in the Cargo `OUT_DIR`.
//!   3. Instruct Cargo to link these static libraries (`-l static=<name>`) and to search for them
//!      in `OUT_DIR`.
//!   4. Add a linker flag `-no-pie` to disable Position Independent Executable (PIE) generation,
//!      because the assembly code contains absolute relocations that are incompatible with PIE.
//!
//! This script assumes that the object files have already been assembled (e.g., by a Makefile
//! or prior build step) and placed in `../build/`. It does **not** invoke the assembler itself.
//!
//! # Panics
//!
//! The script will panic with a descriptive message if:
//!   - The `ar` command is not available (i.e., its `--version` check fails).
//!   - Creating a static library fails (the `ar` command returns a non‑zero exit status).
//!   - The environment variable `OUT_DIR` is not set (Cargo always sets it).

use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    // ------------------------------------------------------------------------
    // Define the base names of the assembly object files (without the .o suffix).
    // These correspond to files like `../build/_start.o`, `../build/executor.o`, etc.
    // ------------------------------------------------------------------------
    let obj_files: [&str; 5] = ["_start", "executor", "memfd", "util", "writer"];

    // ------------------------------------------------------------------------
    // Verify that the `ar` archiver is available by checking its version.
    // On most Linux systems, `ar` is provided by the binutils package.
    // If `ar` is not found or cannot be executed, panic with a helpful message.
    // ------------------------------------------------------------------------
    let ar = match Command::new("ar").arg("--version").output() {
        Ok(output) if output.status.success() => "ar",
        _ => panic!("ar not available. Install binutils (apt install binutils)"),
    };

    // ------------------------------------------------------------------------
    // Determine output and source directories:
    //   - `out_dir` : the directory where Cargo expects build script outputs
    //                 (set via the `OUT_DIR` environment variable).
    //   - `build_dir`: the directory containing the pre‑assembled object files
    //                 (relative to the crate root).
    // ------------------------------------------------------------------------
    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());
    let build_dir = PathBuf::from("../build");

    // ------------------------------------------------------------------------
    // For each object file, create a static archive (.a) in `out_dir`.
    // The command used is: `ar rcs lib<name>.a <name>.o`
    //   - `r`    : insert the files into the archive (replacing existing ones).
    //   - `c`    : create the archive silently if it doesn't exist.
    //   - `s`    : write an object‑file index into the archive (required for linking).
    // ------------------------------------------------------------------------
    for obj in &obj_files {
        let obj_path = build_dir.join(format!("{}.o", obj));
        let lib_path = out_dir.join(format!("lib{}.a", obj));

        // Execute the `ar` command.
        let status = Command::new(ar)
            .args([
                "rcs",
                lib_path.to_str().unwrap(),
                obj_path.to_str().unwrap(),
            ])
            .status()
            .expect("Failed to run ar");

        // If `ar` returned a non‑zero exit status, the archive creation failed.
        if !status.success() {
            panic!("Failed to create static library for {}", obj);
        }

        // --------------------------------------------------------------------
        // Instruct Cargo to link the static library.
        //   - `cargo:rustc-link-search=native={}` adds a directory to the
        //     linker's search path.
        //   - `cargo:rustc-link-lib=static={}` tells the linker to link
        //     `lib{}.a` as a static library.
        // These directives are interpreted by Cargo and passed to `rustc`.
        // --------------------------------------------------------------------
        println!("cargo:rustc-link-search=native={}", out_dir.display());
        println!("cargo:rustc-link-lib=static={}", obj);
    }

    // ------------------------------------------------------------------------
    // CRITICAL LINKER FIX: Disable Position Independent Executable (PIE).
    //
    // The assembly objects contain absolute relocations (e.g., references to
    // fixed addresses). When the linker creates a PIE (the default on many
    // modern distributions), it expects all code to be position‑independent.
    // Absolute relocations are not allowed in PIEs and would cause linking
    // errors or runtime crashes. Adding `-no-pie` forces the creation of a
    // traditional non‑PIE executable, which supports absolute addressing.
    //
    // This flag is passed directly to the linker via `rustc`.
    // ------------------------------------------------------------------------
    println!("cargo:rustc-link-arg=-no-pie");
}
