//! The contract every node type implements, plus helpers shared by node implementations.

use crate::engine::context::Item;
use crate::engine::workflow::WorkflowNode;
use crate::errors::{ErrorKind, Result, fail};
use crate::expression::{Scope, render};
use crate::value::{Obj, Val, get_key, to_num, to_template_str};

#[derive(Debug, Clone, Copy)]
pub enum ParamKind {
    Text,
    Number,
    Boolean,
    Select,
    Json,
    Conditions,
    Rules,
    Fields,
    KeyValues,
    Credential,
    Workflow,
    Code,
    Tools,
}

impl ParamKind {
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Text => "text",
            Self::Number => "number",
            Self::Boolean => "boolean",
            Self::Select => "select",
            Self::Json => "json",
            Self::Conditions => "conditions",
            Self::Rules => "rules",
            Self::Fields => "fields",
            Self::KeyValues => "keyValues",
            Self::Credential => "credential",
            Self::Workflow => "workflow",
            Self::Code => "code",
            Self::Tools => "tools",
        }
    }
}

/// A parameter default, kept `const` so node specs can be static.
#[derive(Debug, Clone, Copy)]
pub enum Default {
    Text(&'static str),
    Number(f64),
    Bool(bool),
    EmptyList,
}

impl Default {
    #[must_use]
    pub fn to_val(self) -> Val {
        match self {
            Self::Text(s) => Val::from(s),
            Self::Number(n) => Val::Num(n),
            Self::Bool(b) => Val::Bool(b),
            Self::EmptyList => Val::Arr(Vec::new()),
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub struct ParamSpec {
    pub key: &'static str,
    pub label: &'static str,
    pub kind: ParamKind,
    pub default: Default,
    pub options: Option<&'static [&'static str]>,
    pub hint: Option<&'static str>,
}

impl ParamSpec {
    #[must_use]
    pub const fn new(
        key: &'static str,
        label: &'static str,
        kind: ParamKind,
        default: Default,
    ) -> Self {
        Self {
            key,
            label,
            kind,
            default,
            options: None,
            hint: None,
        }
    }

    #[must_use]
    pub const fn options(mut self, options: &'static [&'static str]) -> Self {
        self.options = Some(options);
        self
    }

    #[must_use]
    pub const fn hint(mut self, hint: &'static str) -> Self {
        self.hint = Some(hint);
        self
    }
}

#[derive(Debug, Clone, Copy)]
pub enum NodeGroup {
    Trigger,
    Flow,
    Data,
    Network,
    Android,
    Ai,
    Communication,
    Database,
    Productivity,
    System,
}

impl NodeGroup {
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Trigger => "trigger",
            Self::Flow => "flow",
            Self::Data => "data",
            Self::Network => "network",
            Self::Android => "android",
            Self::Ai => "ai",
            Self::Communication => "communication",
            Self::Database => "database",
            Self::Productivity => "productivity",
            Self::System => "system",
        }
    }
}

pub struct NodeRun<'a> {
    pub node: &'a WorkflowNode,
    /// The node's parameters with spec defaults filled in.
    pub params: Obj,
    /// Items per input; most nodes read only `inputs[0]`.
    pub inputs: &'a [Vec<Item>],
    /// Expression variables shared by every item.
    pub base: Obj,
    /// In `run`: what this node kept from its previous run in this execution
    /// (its memory), or null. In `step`: the memo it returned with its last effect.
    pub memo: Val,
}

/// A node either produces outputs now, or asks the host to perform an effect first.
pub enum NodeResult {
    Outputs(Vec<Vec<Item>>),
    Effect(Obj),
    /// Outputs, plus what to keep for the node's next run (null forgets it).
    OutputsWithMemory(Vec<Vec<Item>>, Val),
    /// An effect, plus the memo that comes back in `step`.
    EffectWithMemo(Obj, Val),
}

/// After an effect: outputs, or another effect for a node that needs several round trips.
pub enum StepResult {
    Outputs(Vec<Vec<Item>>),
    Effect(Obj, Val),
}

pub type RunFn = fn(&NodeRun<'_>) -> Result<NodeResult>;
pub type ResumeFn = fn(&NodeRun<'_>, &Obj) -> Result<Vec<Vec<Item>>>;
pub type StepFn = fn(&NodeRun<'_>, &Obj) -> Result<StepResult>;

pub struct NodeSpec {
    pub type_name: &'static str,
    pub label: &'static str,
    pub group: NodeGroup,
    pub description: &'static str,
    pub inputs: usize,
    /// Output labels; `None` when they come from the `rules` parameter (Switch).
    pub outputs: Option<&'static [&'static str]>,
    pub params: &'static [ParamSpec],
    pub run: RunFn,
    /// Turns the host's effect result into outputs; only for effect nodes.
    pub resume: Option<ResumeFn>,
    /// Like `resume`, but may ask for another effect; used instead of it when present.
    pub step: Option<StepFn>,
}

impl NodeRun<'_> {
    #[must_use]
    pub fn items(&self) -> &[Item] {
        self.inputs.first().map_or(&[], Vec::as_slice)
    }

    #[must_use]
    pub fn param(&self, key: &str) -> &Val {
        get_key(&self.params, key)
    }

    /// The expression scope for item `index` (an empty item past the end).
    #[must_use]
    pub fn scope(&self, index: usize) -> Scope<'_> {
        match self.items().get(index) {
            Some(item) => Scope::with_item(&self.base, item, index),
            None => Scope::with_item(&self.base, &Obj::new(), index),
        }
    }

    /// A parameter rendered for one item.
    pub fn value(&self, key: &str, index: usize) -> Result<Val> {
        render(self.param(key), &self.scope(index))
    }

    pub fn text(&self, key: &str, index: usize) -> Result<String> {
        Ok(to_template_str(&self.value(key, index)?))
    }

    pub fn number(&self, key: &str, index: usize) -> Result<f64> {
        Ok(to_num(&self.value(key, index)?))
    }

    /// Rows of a list parameter (`fields`, `keyValues`, `rules`); each must be an object.
    pub fn rows(&self, key: &str) -> Result<Vec<&Obj>> {
        let Val::Arr(list) = self.param(key) else {
            return Ok(Vec::new());
        };
        list.iter()
            .enumerate()
            .map(|(i, row)| match row {
                Val::Obj(o) => Ok(o),
                _ => fail(ErrorKind::Node, format!("{key} row {i} must be an object")),
            })
            .collect()
    }
}

pub fn pass_through(run: &NodeRun<'_>) -> Result<NodeResult> {
    Ok(NodeResult::Outputs(vec![run.items().to_vec()]))
}

/// Fails with the host's error, if the effect result carries one.
pub fn check_effect_error(result: &Obj) -> Result<()> {
    match get_key(result, "error") {
        Val::Str(error) => fail(ErrorKind::Node, error.clone()),
        _ => Ok(()),
    }
}

/// Resume for effects that produce nothing: fail on error, else pass the items on.
pub fn resume_pass_through(run: &NodeRun<'_>, result: &Obj) -> Result<Vec<Vec<Item>>> {
    check_effect_error(result)?;
    Ok(vec![run.items().to_vec()])
}

/// Copies of `items`, each with `field` set to `value`.
#[must_use]
pub fn with_field(items: &[Item], field: &str, value: &Val) -> Vec<Item> {
    items
        .iter()
        .map(|item| {
            let mut copy = item.clone();
            copy.insert(field.to_owned(), value.clone());
            copy
        })
        .collect()
}
