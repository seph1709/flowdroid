//! The Rust port of `src/api.ts`.
//!
//! The engine itself lives in the `flowcore-engine` crate (pure Rust, no
//! bindings) so the Android app can link it directly; this file adapts it to
//! the generated bindings. Errors cross the bridge as `"<Kind>: message"`,
//! the text the TypeScript original throws.

#![forbid(unsafe_code)]

/// Port of `evaluateTemplate` (`src/api.ts:22`).
pub fn evaluate_template(template: String, context_json: String) -> Result<String, String> {
    flowcore_engine::evaluate_template(&template, &context_json).map_err(|e| e.to_string())
}

/// Port of `validateWorkflow` (`src/api.ts:29`).
pub fn validate_workflow(workflow_json: String) -> Result<String, String> {
    flowcore_engine::validate_workflow(&workflow_json).map_err(|e| e.to_string())
}

/// Port of `nodeCatalog` (`src/api.ts:34`).
pub fn node_catalog() -> Result<String, String> {
    Ok(flowcore_engine::node_catalog())
}

/// Port of `startExecution` (`src/api.ts:42`).
pub fn start_execution(
    workflow_json: String,
    trigger_node_id: String,
    items_json: String,
    now_ms: f64,
) -> Result<String, String> {
    flowcore_engine::start_execution(&workflow_json, &trigger_node_id, &items_json, now_ms)
        .map_err(|e| e.to_string())
}

/// Port of `resumeExecution` (`src/api.ts:51`).
pub fn resume_execution(
    workflow_json: String,
    state_json: String,
    result_json: String,
    now_ms: f64,
) -> Result<String, String> {
    flowcore_engine::resume_execution(&workflow_json, &state_json, &result_json, now_ms)
        .map_err(|e| e.to_string())
}

/// Port of `nextCronRun` (`src/api.ts:61`).
pub fn next_cron_run(
    expression: String,
    after_ms: f64,
    utc_offset_minutes: f64,
) -> Result<f64, String> {
    flowcore_engine::next_cron_run(&expression, after_ms, utc_offset_minutes)
        .map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn errors_carry_the_original_message() {
        assert_eq!(
            evaluate_template("{{ 1 + }}".into(), "{}".into()),
            Err("ExpressionError: unexpected end of expression".into())
        );
        assert_eq!(
            next_cron_run("* * * *".into(), 0.0, 0.0),
            Err("CronError: expected 5 fields".into())
        );
    }

    #[test]
    fn runs_a_template() {
        assert_eq!(
            evaluate_template(
                "Hi {{ $json.name }}".into(),
                r#"{"$json":{"name":"Ann"}}"#.into()
            ),
            Ok(r#""Hi Ann""#.into())
        );
    }
}
