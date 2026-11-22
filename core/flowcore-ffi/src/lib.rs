//! C ABI over `flowcore-engine` for the Flutter app.
//!
//! One entry point keeps the unsafe surface small:
//!
//! ```c
//! char *flowcore_call(const char *request);  // {"fn": "...", "args": [...]}
//! void  flowcore_free(char *response);
//! ```
//!
//! The response is always JSON: `{"ok": <result>}` or `{"error": "<Kind>: message"}`.
//! Functions that return JSON documents embed them as values, not strings.

use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

use flowcore_engine::json::parse_json;
use flowcore_engine::value::{Val, format_number, get_key, obj, stringify};
use flowcore_engine::{
    ErrorKind, evaluate_template, next_cron_run, node_catalog, resume_execution, start_execution,
    validate_workflow,
};

/// The response text for one request.
fn dispatch(request: &str) -> String {
    match handle(request) {
        Ok(json) => format!("{{\"ok\":{json}}}"),
        Err(message) => stringify(&Val::Obj(obj([("error", Val::Str(message))]))),
    }
}

fn handle(request: &str) -> Result<String, String> {
    let request = parse_json(request, "request", ErrorKind::Input).map_err(|e| e.to_string())?;
    let Val::Obj(request) = request else {
        return Err("InputError: request must be an object".into());
    };
    let name = get_key(&request, "fn")
        .as_str()
        .unwrap_or_default()
        .to_owned();
    let args = get_key(&request, "args")
        .as_arr()
        .cloned()
        .unwrap_or_default();
    let text = |i: usize| args.get(i).and_then(Val::as_str).unwrap_or_default();
    let number = |i: usize| match args.get(i) {
        Some(Val::Num(n)) => *n,
        _ => f64::NAN,
    };
    let result = match name.as_str() {
        "evaluateTemplate" => evaluate_template(text(0), text(1)),
        "validateWorkflow" => validate_workflow(text(0)),
        "nodeCatalog" => Ok(node_catalog()),
        "startExecution" => start_execution(text(0), text(1), text(2), number(3)),
        "resumeExecution" => resume_execution(text(0), text(1), text(2), number(3)),
        "nextCronRun" => next_cron_run(text(0), number(1), number(2)).map(format_number),
        _ => return Err(format!("InputError: unknown function {name}")),
    };
    result.map_err(|e| e.to_string())
}

/// Runs one request. The caller owns the returned string and must pass it to
/// [`flowcore_free`]. Returns null only if `request` is null.
///
/// # Safety
///
/// `request` must be null or point to a NUL-terminated string that stays
/// valid for the duration of the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn flowcore_call(request: *const c_char) -> *mut c_char {
    if request.is_null() {
        return std::ptr::null_mut();
    }
    // SAFETY: the caller guarantees a valid NUL-terminated string (see above).
    let request = unsafe { CStr::from_ptr(request) }.to_string_lossy();
    let response = catch_unwind(AssertUnwindSafe(|| dispatch(&request)))
        .unwrap_or_else(|_| r#"{"error":"InternalError: the core panicked"}"#.to_owned());
    // JSON text never contains a raw NUL (it is escaped as \u0000).
    CString::new(response).map_or(std::ptr::null_mut(), CString::into_raw)
}

/// Frees a string returned by [`flowcore_call`]. Null is ignored.
///
/// # Safety
///
/// `response` must be null or a pointer returned by `flowcore_call` that has
/// not been freed yet.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn flowcore_free(response: *mut c_char) {
    if !response.is_null() {
        // SAFETY: the pointer came from `CString::into_raw` in `flowcore_call`.
        drop(unsafe { CString::from_raw(response) });
    }
}

#[cfg(test)]
mod tests {
    use super::dispatch;

    #[test]
    fn wraps_results_and_errors() {
        assert_eq!(
            dispatch(r#"{"fn":"evaluateTemplate","args":["{{ 1 + 1 }}","{}"]}"#),
            r#"{"ok":2}"#
        );
        assert_eq!(
            dispatch(r#"{"fn":"nextCronRun","args":["0 0 30 2 *",0,0]}"#),
            r#"{"ok":-1}"#
        );
        assert_eq!(
            dispatch(r#"{"fn":"nope"}"#),
            r#"{"error":"InputError: unknown function nope"}"#
        );
        assert_eq!(
            dispatch("x"),
            r#"{"error":"InputError: request is not valid JSON"}"#
        );
    }
}
