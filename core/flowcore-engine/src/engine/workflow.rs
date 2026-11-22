//! Workflow documents: parsing untrusted JSON into a checked model.

use crate::errors::{ErrorKind, Result, fail};
use crate::json::parse_json;
use crate::value::{Obj, Val, get_key};

#[derive(Debug, Clone)]
pub struct WorkflowNode {
    pub id: String,
    pub name: String,
    pub type_name: String,
    pub params: Obj,
    pub disabled: bool,
    pub continue_on_fail: bool,
    /// Output saved in the editor, used instead of running the node when `use_pinned` is set.
    pub pinned: Option<Vec<Obj>>,
    /// After a failed effect, run the node again up to `max_tries` times in all.
    pub retry_on_fail: bool,
    pub max_tries: f64,
    /// Milliseconds between tries.
    pub wait_between_tries: f64,
}

/// Most tries a node may ask for.
pub const MAX_TRIES: f64 = 10.0;
/// Longest wait between tries: five minutes.
pub const MAX_WAIT_BETWEEN_TRIES: f64 = 300_000.0;

#[derive(Debug, Clone)]
pub struct Connection {
    pub from: String,
    pub output: usize,
    pub to: String,
    pub input: usize,
}

#[derive(Debug, Clone)]
pub struct Workflow {
    pub id: String,
    pub name: String,
    pub nodes: Vec<WorkflowNode>,
    pub connections: Vec<Connection>,
    pub variables: Obj,
    /// Manual test runs set this so nodes with pinned output reuse it.
    pub use_pinned: bool,
}

/// Highest number of inputs or outputs a node can have.
pub const MAX_PORTS: usize = 64;

pub fn parse_workflow(json: &str) -> Result<Workflow> {
    let doc = parse_json(json, "workflow", ErrorKind::Input)?;
    let Val::Obj(doc) = doc else {
        return fail(ErrorKind::Input, "workflow must be an object");
    };
    let Val::Arr(nodes) = get_key(&doc, "nodes") else {
        return fail(ErrorKind::Input, "workflow.nodes must be an array");
    };
    let connections: &[Val] = match get_key(&doc, "connections") {
        Val::Null => &[],
        Val::Arr(list) => list,
        _ => return fail(ErrorKind::Input, "workflow.connections must be an array"),
    };
    Ok(Workflow {
        id: text(get_key(&doc, "id"), ""),
        name: text(get_key(&doc, "name"), ""),
        nodes: nodes
            .iter()
            .enumerate()
            .map(|(i, v)| parse_node(v, i))
            .collect::<Result<_>>()?,
        connections: connections
            .iter()
            .enumerate()
            .map(|(i, v)| parse_connection(v, i))
            .collect::<Result<_>>()?,
        variables: object_or(get_key(&doc, "variables")),
        use_pinned: get_key(&doc, "usePinnedData").is_true(),
    })
}

fn parse_node(v: &Val, index: usize) -> Result<WorkflowNode> {
    let Val::Obj(o) = v else {
        return fail(ErrorKind::Input, format!("node {index} must be an object"));
    };
    let id = text(get_key(o, "id"), "");
    if id.is_empty() {
        return fail(ErrorKind::Input, format!("node {index} has no id"));
    }
    let type_name = text(get_key(o, "type"), "");
    if type_name.is_empty() {
        return fail(ErrorKind::Input, format!("node {index} has no type"));
    }
    Ok(WorkflowNode {
        name: text(get_key(o, "name"), &id),
        id,
        type_name,
        params: object_or(get_key(o, "params")),
        disabled: get_key(o, "disabled").is_true(),
        continue_on_fail: get_key(o, "continueOnFail").is_true(),
        pinned: get_key(o, "pinned").as_arr().and_then(|list| {
            list.iter()
                .map(|v| v.as_obj().cloned())
                .collect::<Option<Vec<_>>>()
        }),
        retry_on_fail: get_key(o, "retryOnFail").is_true(),
        max_tries: clamp_int(get_key(o, "maxTries"), 3.0, 1.0, MAX_TRIES),
        wait_between_tries: clamp_int(
            get_key(o, "waitBetweenTries"),
            1000.0,
            0.0,
            MAX_WAIT_BETWEEN_TRIES,
        ),
    })
}

/// A whole number within `[min, max]`; `fallback` when `v` is not a finite number.
fn clamp_int(v: &Val, fallback: f64, min: f64, max: f64) -> f64 {
    match v {
        Val::Num(n) if n.is_finite() => n.trunc().max(min).min(max) + 0.0,
        _ => fallback,
    }
}

fn parse_connection(v: &Val, index: usize) -> Result<Connection> {
    let Val::Obj(o) = v else {
        return fail(
            ErrorKind::Input,
            format!("connection {index} must be an object"),
        );
    };
    Ok(Connection {
        from: text(get_key(o, "from"), ""),
        output: port(get_key(o, "output")).unwrap_or(0),
        to: text(get_key(o, "to"), ""),
        input: port(get_key(o, "input")).unwrap_or(0),
    })
}

fn text(v: &Val, fallback: &str) -> String {
    v.as_str().unwrap_or(fallback).to_owned()
}

fn object_or(v: &Val) -> Obj {
    v.as_obj().cloned().unwrap_or_default()
}

/// A valid port index: an integer in `[0, MAX_PORTS)`.
#[must_use]
pub fn port(v: &Val) -> Option<usize> {
    match v {
        Val::Num(n) if n.fract() == 0.0 && *n >= 0.0 && *n < MAX_PORTS as f64 => Some(*n as usize),
        _ => None,
    }
}

impl Workflow {
    #[must_use]
    pub fn node(&self, id: &str) -> Option<&WorkflowNode> {
        self.nodes.iter().find(|n| n.id == id)
    }

    /// Connections leaving `node_id` that lead to an existing node.
    pub fn outgoing<'a>(&'a self, node_id: &'a str) -> impl Iterator<Item = &'a Connection> {
        self.connections
            .iter()
            .filter(move |c| c.from == node_id && self.node(&c.to).is_some())
    }

    /// Input indexes of `node_id` that some existing node feeds, ascending.
    #[must_use]
    pub fn connected_inputs(&self, node_id: &str) -> Vec<usize> {
        let mut inputs: Vec<usize> = self
            .connections
            .iter()
            .filter(|c| c.to == node_id && self.node(&c.from).is_some())
            .map(|c| c.input)
            .collect();
        inputs.sort_unstable();
        inputs.dedup();
        inputs
    }
}
