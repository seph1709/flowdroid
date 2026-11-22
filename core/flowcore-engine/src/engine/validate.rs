//! Static checks the editor shows before a workflow runs.

use std::collections::HashSet;

use super::nodes::{is_trigger, spec_for};
use super::workflow::Workflow;
use crate::expression::check_templates;
use crate::value::Val;

#[must_use]
pub fn validate(wf: &Workflow) -> Vec<String> {
    let mut issues = Vec::new();
    if !wf.nodes.iter().any(|n| is_trigger(&n.type_name)) {
        issues.push("workflow has no trigger node".to_owned());
    }
    let mut ids = HashSet::new();
    let mut names = HashSet::new();
    for node in &wf.nodes {
        if !ids.insert(node.id.as_str()) {
            issues.push(format!("duplicate node id {}", node.id));
        }
        if !names.insert(node.name.as_str()) {
            issues.push(format!("duplicate node name {}", node.name));
        }
        if spec_for(&node.type_name).is_none() {
            issues.push(format!(
                "{}: unknown node type {}",
                node.name, node.type_name
            ));
        }
        check_templates(&Val::Obj(node.params.clone()), &mut |message| {
            issues.push(format!("{}: {message}", node.name));
        });
    }
    for (i, c) in wf.connections.iter().enumerate() {
        if wf.node(&c.from).is_none() {
            issues.push(format!("connection {i}: unknown source node {}", c.from));
        }
        if wf.node(&c.to).is_none() {
            issues.push(format!("connection {i}: unknown target node {}", c.to));
        }
    }
    issues
}
