//! FlowDroid workflow core.
//!
//! A port of the TypeScript reference in `engine-ts/`, checked case by case
//! with `rust-anything`. Every public function takes and returns strings and
//! numbers only, with JSON documents as text, so it can sit behind napi, FFI
//! or Dart. Errors display as `"<Kind>: message"`.

pub mod cron;
pub mod engine;
pub mod errors;
pub mod expression;
pub mod json;
pub mod time;
pub mod value;

use engine::executor::{resume, start};
use engine::nodes::catalog;
use engine::state::ExecutionState;
use engine::validate::validate;
use engine::workflow::parse_workflow;
use errors::fail;
pub use errors::{Error, ErrorKind, Result};
use expression::{Scope, render_template};
use json::parse_json;
use time::check_time;
use value::{Val, stringify};

/// Renders a `{{ }}` template against a JSON object of variables; returns the result as JSON.
pub fn evaluate_template(template: &str, context_json: &str) -> Result<String> {
    let Val::Obj(ctx) = parse_json(context_json, "context", ErrorKind::Input)? else {
        return fail(ErrorKind::Input, "context must be an object");
    };
    Ok(stringify(&render_template(template, &Scope::new(&ctx))?))
}

/// Returns a JSON list of problems (empty when the workflow looks runnable).
pub fn validate_workflow(workflow_json: &str) -> Result<String> {
    let issues = validate(&parse_workflow(workflow_json)?);
    Ok(stringify(&Val::Arr(
        issues.into_iter().map(Val::Str).collect(),
    )))
}

/// Returns the JSON catalog of node types the editor offers.
#[must_use]
pub fn node_catalog() -> String {
    stringify(&catalog())
}

/// Starts a run at `trigger_node_id` with the trigger's items (a JSON list of
/// objects; an empty list means one empty item). Returns the execution state.
pub fn start_execution(
    workflow_json: &str,
    trigger_node_id: &str,
    items_json: &str,
    now_ms: f64,
) -> Result<String> {
    let wf = parse_workflow(workflow_json)?;
    let items = parse_json(items_json, "items", ErrorKind::Input)?;
    let Some(mut items) = engine::state::as_items(&items) else {
        return fail(ErrorKind::Input, "items must be a list of objects");
    };
    let now = check_time(now_ms, ErrorKind::Input, "now")?;
    if items.is_empty() {
        items.push(value::Obj::new());
    }
    Ok(start(&wf, trigger_node_id, items, now)?.to_json())
}

/// Continues a `waiting` execution with the host's result for `pending.effect`.
pub fn resume_execution(
    workflow_json: &str,
    state_json: &str,
    result_json: &str,
    now_ms: f64,
) -> Result<String> {
    let wf = parse_workflow(workflow_json)?;
    let state = ExecutionState::parse(state_json, &wf)?;
    let Val::Obj(result) = parse_json(result_json, "effect result", ErrorKind::Input)? else {
        return fail(ErrorKind::Input, "effect result must be an object");
    };
    let now = check_time(now_ms, ErrorKind::Input, "now")?;
    Ok(resume(&wf, state, &result, now)?.to_json())
}

/// Next run of a cron expression after `after_ms` (UTC ms); -1 if it never fires.
pub fn next_cron_run(expression: &str, after_ms: f64, utc_offset_minutes: f64) -> Result<f64> {
    cron::next_run(expression, after_ms, utc_offset_minutes)
}
