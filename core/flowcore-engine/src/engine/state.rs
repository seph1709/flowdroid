//! Execution state, stored by the host between steps and passed back to resume.

use std::collections::VecDeque;

use super::context::Item;
use super::workflow::{Workflow, port};
use crate::errors::{ErrorKind, Result, fail};
use crate::json::parse_json;
use crate::value::{Obj, Val, get_key, obj, stringify};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Running,
    Waiting,
    Success,
    Error,
}

impl Status {
    fn as_str(self) -> &'static str {
        match self {
            Self::Running => "running",
            Self::Waiting => "waiting",
            Self::Success => "success",
            Self::Error => "error",
        }
    }
}

/// Items delivered to one input of a node, not yet run.
#[derive(Debug, Clone)]
pub struct Task {
    pub node: String,
    pub input: usize,
    pub items: Vec<Item>,
}

/// An effect node waiting for the host's result.
#[derive(Debug, Clone)]
pub struct Pending {
    pub node: String,
    pub inputs: Vec<Vec<Item>>,
    pub effect: Obj,
    /// The node's own progress between round trips (AI Agent).
    pub memo: Val,
    /// Which try this is, from 1.
    pub attempt: f64,
    /// True while waiting before the node runs again after a failure.
    pub retry: bool,
}

#[derive(Debug, Clone)]
pub struct ExecutionState {
    pub status: Status,
    pub error: Option<String>,
    pub started_at: f64,
    pub finished_at: Option<f64>,
    pub steps: f64,
    pub pending: Option<Pending>,
    pub queue: VecDeque<Task>,
    /// Multi-input nodes collecting inputs, by node id: one slot per input.
    pub waiting: Obj,
    /// What a node keeps between its runs in one execution (Loop Over Items), by node id.
    pub memory: Obj,
    /// Latest output of each node, by node name, for `$node`.
    pub last: Obj,
    /// One record per node run, in order.
    pub runs: Vec<Val>,
}

fn items_list(items: &[Item]) -> Val {
    Val::Arr(items.iter().cloned().map(Val::Obj).collect())
}

fn inputs_list(inputs: &[Vec<Item>]) -> Val {
    Val::Arr(inputs.iter().map(|items| items_list(items)).collect())
}

impl ExecutionState {
    #[must_use]
    pub fn new(now: f64) -> Self {
        Self {
            status: Status::Running,
            error: None,
            started_at: now,
            finished_at: None,
            steps: 0.0,
            pending: None,
            queue: VecDeque::new(),
            waiting: Obj::new(),
            memory: Obj::new(),
            last: Obj::new(),
            runs: Vec::new(),
        }
    }

    #[must_use]
    pub fn to_json(&self) -> String {
        let pending = self.pending.as_ref().map(|p| {
            Val::Obj(obj([
                ("node", p.node.as_str().into()),
                ("inputs", inputs_list(&p.inputs)),
                ("effect", Val::Obj(p.effect.clone())),
                ("memo", p.memo.clone()),
                ("attempt", Val::Num(p.attempt)),
                ("retry", Val::Bool(p.retry)),
            ]))
        });
        let queue = self
            .queue
            .iter()
            .map(|t| {
                Val::Obj(obj([
                    ("node", t.node.as_str().into()),
                    ("input", t.input.into()),
                    ("items", items_list(&t.items)),
                ]))
            })
            .collect();
        stringify(&Val::Obj(obj([
            ("status", self.status.as_str().into()),
            ("error", self.error.clone().into()),
            ("startedAt", Val::Num(self.started_at)),
            ("finishedAt", self.finished_at.into()),
            ("steps", Val::Num(self.steps)),
            ("pending", pending.into()),
            ("queue", Val::Arr(queue)),
            ("waiting", Val::Obj(self.waiting.clone())),
            ("memory", Val::Obj(self.memory.clone())),
            ("last", Val::Obj(self.last.clone())),
            ("runs", Val::Arr(self.runs.clone())),
        ])))
    }

    /// Parses a state saved by [`ExecutionState::to_json`]; it must be waiting for an effect result.
    pub fn parse(json: &str, wf: &Workflow) -> Result<Self> {
        let Val::Obj(doc) = parse_json(json, "state", ErrorKind::Input)? else {
            return fail(ErrorKind::Input, "state must be an object");
        };
        if !get_key(&doc, "status").is_str("waiting") {
            return fail(
                ErrorKind::Input,
                "execution is not waiting for an effect result",
            );
        }
        let steps = match get_key(&doc, "steps") {
            Val::Num(n) if n.fract() == 0.0 && *n >= 0.0 => *n + 0.0,
            _ => return invalid("steps"),
        };
        let Val::Num(started_at) = get_key(&doc, "startedAt") else {
            return invalid("startedAt");
        };
        let Val::Arr(runs) = get_key(&doc, "runs") else {
            return invalid("runs");
        };
        Ok(Self {
            status: Status::Waiting,
            error: None,
            started_at: *started_at,
            finished_at: None,
            steps,
            pending: Some(parse_pending(get_key(&doc, "pending"), wf)?),
            queue: parse_queue(get_key(&doc, "queue"), wf)?,
            waiting: object_of(get_key(&doc, "waiting"), "waiting", |slots| {
                slots
                    .as_arr()
                    .is_some_and(|list| list.iter().all(|s| s.is_null() || as_items(s).is_some()))
            })?,
            memory: match get_key(&doc, "memory") {
                Val::Null => Obj::new(),
                v => object_of(v, "memory", |_| true)?,
            },
            last: object_of(get_key(&doc, "last"), "last", |v| as_items(v).is_some())?,
            runs: runs.clone(),
        })
    }
}

fn invalid<T>(field: &str) -> Result<T> {
    fail(ErrorKind::Input, format!("state.{field} is invalid"))
}

/// The value as a list of items, when it is a list of objects.
#[must_use]
pub fn as_items(v: &Val) -> Option<Vec<Item>> {
    v.as_arr()?
        .iter()
        .map(|item| item.as_obj().cloned())
        .collect()
}

fn node_id(v: &Val, wf: &Workflow) -> Option<String> {
    v.as_str()
        .filter(|id| wf.node(id).is_some())
        .map(str::to_owned)
}

fn parse_pending(v: &Val, wf: &Workflow) -> Result<Pending> {
    let Val::Obj(p) = v else {
        return invalid("pending");
    };
    let node = node_id(get_key(p, "node"), wf);
    let inputs = get_key(p, "inputs")
        .as_arr()
        .and_then(|list| list.iter().map(as_items).collect::<Option<Vec<_>>>());
    match (node, inputs, get_key(p, "effect")) {
        (Some(node), Some(inputs), Val::Obj(effect)) => {
            let attempt = match get_key(p, "attempt") {
                Val::Null => 1.0,
                Val::Num(n) if n.fract() == 0.0 && *n >= 1.0 => *n + 0.0,
                _ => return invalid("pending"),
            };
            Ok(Pending {
                node,
                inputs,
                effect: effect.clone(),
                memo: get_key(p, "memo").clone(),
                attempt,
                retry: get_key(p, "retry").is_true(),
            })
        }
        _ => invalid("pending"),
    }
}

fn parse_queue(v: &Val, wf: &Workflow) -> Result<VecDeque<Task>> {
    let Val::Arr(list) = v else {
        return invalid("queue");
    };
    list.iter()
        .map(|t| {
            let Val::Obj(t) = t else {
                return invalid("queue");
            };
            match (
                node_id(get_key(t, "node"), wf),
                port(get_key(t, "input")),
                as_items(get_key(t, "items")),
            ) {
                (Some(node), Some(input), Some(items)) => Ok(Task { node, input, items }),
                _ => invalid("queue"),
            }
        })
        .collect()
}

fn object_of(v: &Val, field: &str, check: impl Fn(&Val) -> bool) -> Result<Obj> {
    match v {
        Val::Obj(o) if o.values().all(check) => Ok(o.clone()),
        _ => invalid(field),
    }
}
