//! Send Email over SMTP; see `integrations/email.ts`.

use super::super::file_refs::file_paths;
use super::super::spec::{
    Default, NodeGroup, NodeResult, NodeRun, NodeSpec, ParamKind, ParamSpec, resume_pass_through,
};
use super::api::{credential_name, credential_param};
use crate::errors::{ErrorKind, Result, fail};
use crate::value::{Val, obj};

fn send(run: &NodeRun<'_>) -> Result<NodeResult> {
    let credential = credential_name(run)?;
    let html = run.param("html").is_true();
    let messages = (0..run.items().len())
        .map(|i| {
            let to = run.text("to", i)?;
            if to.is_empty() {
                return fail(ErrorKind::Node, "recipient is required");
            }
            let mut message = obj([
                ("to", Val::Str(to)),
                ("subject", Val::Str(run.text("subject", i)?)),
                ("text", Val::Str(run.text("text", i)?)),
                ("html", Val::Bool(html)),
            ]);
            let attachments = file_paths(run, "attachments", i)?;
            if !attachments.is_empty() {
                message.insert(
                    "attachments".into(),
                    Val::Arr(attachments.into_iter().map(Val::Str).collect()),
                );
            }
            Ok(Val::Obj(message))
        })
        .collect::<Result<Vec<_>>>()?;
    Ok(NodeResult::Effect(obj([
        ("type", "email".into()),
        ("credential", Val::Str(credential)),
        ("messages", Val::Arr(messages)),
    ])))
}

pub static EMAIL_NODES: &[NodeSpec] = &[NodeSpec {
    type_name: "email.send",
    label: "Send Email",
    group: NodeGroup::Communication,
    description: "Sends an email per item through your mail server (SMTP).",
    inputs: 1,
    outputs: Some(&["main"]),
    params: &[
        credential_param(&["email"]),
        ParamSpec::new("to", "To", ParamKind::Text, Default::Text(""))
            .hint("several: separate with commas"),
        ParamSpec::new("subject", "Subject", ParamKind::Text, Default::Text("")),
        ParamSpec::new("text", "Message", ParamKind::Text, Default::Text("")),
        ParamSpec::new(
            "html",
            "Message is HTML",
            ParamKind::Boolean,
            Default::Bool(false),
        ),
        ParamSpec::new(
            "attachments",
            "Attachments",
            ParamKind::Text,
            Default::Text(""),
        )
        .hint("file paths, separated by commas; or {{ $json.file.path }}"),
    ],
    run: send,
    resume: Some(resume_pass_through),
    step: None,
}];
