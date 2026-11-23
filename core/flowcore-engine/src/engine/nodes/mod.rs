//! Node types and the registry the executor and editor use.

mod android;
mod browser;
mod code;
mod control;
mod data;
mod file_refs;
mod flow;
mod http;
pub mod integrations;
mod phone;
pub mod spec;
mod triggers;

use spec::{NodeGroup, NodeSpec};

use crate::engine::workflow::WorkflowNode;
use crate::value::{Obj, Val, obj};

pub fn all_specs() -> impl Iterator<Item = &'static NodeSpec> {
    triggers::TRIGGER_NODES
        .iter()
        .chain(flow::FLOW_NODES)
        .chain(control::CONTROL_NODES)
        .chain(data::DATA_NODES)
        .chain(code::CODE_NODES)
        .chain(http::HTTP_NODES)
        .chain(browser::BROWSER_NODES)
        .chain(android::ANDROID_NODES)
        .chain(phone::PHONE_NODES)
        .chain(integrations::ai::AI_NODES)
        .chain(integrations::knowledge::KNOWLEDGE_NODES)
        .chain(integrations::agent::AGENT_NODES)
        .chain(integrations::mcp::MCP_NODES)
        .chain(integrations::messaging::MESSAGING_NODES)
        .chain(integrations::email::EMAIL_NODES)
        .chain(integrations::databases::DATABASE_NODES)
        .chain(integrations::google::GOOGLE_NODES)
        .chain(integrations::system::SYSTEM_NODES)
        .chain(integrations::files::FILE_NODES)
}

#[must_use]
pub fn spec_for(type_name: &str) -> Option<&'static NodeSpec> {
    all_specs().find(|spec| spec.type_name == type_name)
}

#[must_use]
pub fn is_trigger(type_name: &str) -> bool {
    spec_for(type_name).is_some_and(|spec| matches!(spec.group, NodeGroup::Trigger))
}

/// The node's parameters, with each missing one set to its spec default.
#[must_use]
pub fn params_with_defaults(spec: &NodeSpec, node: &WorkflowNode) -> Obj {
    let mut params: Obj = spec
        .params
        .iter()
        .map(|p| (p.key.to_owned(), p.default.to_val()))
        .collect();
    params.extend(node.params.iter().map(|(k, v)| (k.clone(), v.clone())));
    params
}

fn str_list(list: &[&str]) -> Val {
    Val::Arr(list.iter().map(|s| Val::from(*s)).collect())
}

/// The catalog the editor renders: every node type without its behavior.
#[must_use]
pub fn catalog() -> Val {
    Val::Arr(
        all_specs()
            .map(|spec| {
                let params = spec
                    .params
                    .iter()
                    .map(|p| {
                        Val::Obj(obj([
                            ("key", p.key.into()),
                            ("label", p.label.into()),
                            ("kind", p.kind.as_str().into()),
                            ("default", p.default.to_val()),
                            ("options", p.options.map(str_list).into()),
                            ("hint", p.hint.into()),
                        ]))
                    })
                    .collect();
                Val::Obj(obj([
                    ("type", spec.type_name.into()),
                    ("label", spec.label.into()),
                    ("group", spec.group.as_str().into()),
                    ("description", spec.description.into()),
                    ("inputs", spec.inputs.into()),
                    ("outputs", spec.outputs.map(str_list).into()),
                    ("params", Val::Arr(params)),
                ]))
            })
            .collect(),
    )
}
