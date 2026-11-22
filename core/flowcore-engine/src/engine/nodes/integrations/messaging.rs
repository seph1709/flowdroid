//! Telegram and Discord; see `integrations/messaging.ts`.

use super::super::file_refs::{file_path, is_image_path};
use super::super::spec::{
    Default, NodeGroup, NodeResult, NodeRun, NodeSpec, ParamKind, ParamSpec, pass_through,
};
use super::api::{
    ApiCall, api_request, api_resume, as_items, credential_param, enc, per_item, required,
    with_extra,
};
use crate::engine::context::Item;
use crate::errors::{ErrorKind, Result, fail};
use crate::value::{Obj, Val, get_key, obj, stringify};

fn telegram_send(run: &NodeRun<'_>, index: usize) -> Result<Val> {
    let file = file_path(run, "file", index)?;
    if !file.is_empty() {
        // A photo or document, with the text as its caption.
        let photo = is_image_path(&file);
        let mut parts = vec![
            Val::Obj(obj([
                ("name", "chat_id".into()),
                (
                    "value",
                    Val::Str(required(run, "chatId", index, "chat ID")?),
                ),
            ])),
            Val::Obj(obj([
                ("name", (if photo { "photo" } else { "document" }).into()),
                ("file", Val::Str(file.clone())),
            ])),
        ];
        let caption = run.text("text", index)?;
        if !caption.is_empty() {
            parts.push(Val::Obj(obj([
                ("name", "caption".into()),
                ("value", Val::Str(caption.clone())),
            ])));
        }
        let mode = run.text("parseMode", index)?;
        if mode != "none" && !mode.is_empty() && !caption.is_empty() {
            parts.push(Val::Obj(obj([
                ("name", "parse_mode".into()),
                ("value", Val::Str(mode)),
            ])));
        }
        let request = api_request(
            run,
            ApiCall::new(
                "POST",
                format!(
                    "https://api.telegram.org/bot{{cred:botToken}}/{}",
                    if photo { "sendPhoto" } else { "sendDocument" }
                ),
            ),
        )?;
        return Ok(with_extra(request, "multipart", Val::Arr(parts)));
    }
    let mut body = obj([
        (
            "chat_id",
            Val::Str(required(run, "chatId", index, "chat ID")?),
        ),
        ("text", Val::Str(required(run, "text", index, "text")?)),
    ]);
    let mode = run.text("parseMode", index)?;
    if mode != "none" && !mode.is_empty() {
        body.insert("parse_mode".into(), Val::Str(mode));
    }
    api_request(
        run,
        ApiCall::new(
            "POST",
            "https://api.telegram.org/bot{cred:botToken}/sendMessage",
        )
        .body(Val::Obj(body)),
    )
}

fn telegram_result(body: Val) -> Result<Vec<Item>> {
    if let Val::Obj(o) = &body {
        if matches!(get_key(o, "ok"), Val::Bool(false)) {
            let description = match get_key(o, "description") {
                Val::Str(d) => d.clone(),
                _ => "request failed".to_owned(),
            };
            return fail(ErrorKind::Node, format!("Telegram: {description}"));
        }
    }
    Ok(as_items(match body {
        Val::Obj(mut o) => o.swap_remove("result").unwrap_or_default(),
        other => other,
    }))
}

fn discord_send(run: &NodeRun<'_>, index: usize) -> Result<Val> {
    let file = file_path(run, "file", index)?;
    let content = if file.is_empty() {
        required(run, "content", index, "message")?
    } else {
        run.text("content", index)?
    };
    let bot = run.text("mode", index)? == "bot";
    let mut body = obj([("content", Val::Str(content))]);
    if !bot {
        let username = run.text("username", index)?;
        if !username.is_empty() {
            body.insert("username".into(), Val::Str(username));
        }
    }
    let call = if bot {
        let channel = required(run, "channelId", index, "channel ID")?;
        ApiCall::new(
            "POST",
            format!(
                "https://discord.com/api/v10/channels/{}/messages",
                enc(&channel)
            ),
        )
        .header("Authorization", "Bot {cred:botToken}")
    } else {
        ApiCall::new("POST", "{cred:url}?wait=true")
    };
    if file.is_empty() {
        return api_request(run, call.body(Val::Obj(body)));
    }
    // The message rides along as JSON next to the attached file.
    let request = api_request(run, call)?;
    Ok(with_extra(
        request,
        "multipart",
        Val::Arr(vec![
            Val::Obj(obj([
                ("name", "payload_json".into()),
                ("value", Val::Str(stringify(&Val::Obj(body)))),
            ])),
            Val::Obj(obj([("name", "files[0]".into()), ("file", Val::Str(file))])),
        ]),
    ))
}

fn run_telegram(run: &NodeRun<'_>) -> Result<NodeResult> {
    per_item(run, |i| telegram_send(run, i))
}

fn resume_telegram(_run: &NodeRun<'_>, result: &Obj) -> Result<Vec<Vec<Item>>> {
    api_resume(result, "Telegram", |body, _| telegram_result(body))
}

fn run_discord(run: &NodeRun<'_>) -> Result<NodeResult> {
    per_item(run, |i| discord_send(run, i))
}

fn resume_discord(_run: &NodeRun<'_>, result: &Obj) -> Result<Vec<Vec<Item>>> {
    api_resume(result, "Discord", |body, _| Ok(as_items(body)))
}

pub static MESSAGING_NODES: &[NodeSpec] = &[
    NodeSpec {
        type_name: "trigger.telegram",
        label: "Telegram Trigger",
        group: NodeGroup::Trigger,
        description: "Runs for each message your Telegram bot receives (checked while FlowDroid runs).",
        inputs: 0,
        outputs: Some(&["main"]),
        params: &[
            credential_param(&["telegram"]),
            ParamSpec::new(
                "chatId",
                "Only from chat ID",
                ParamKind::Text,
                Default::Text(""),
            )
            .hint("empty = any chat"),
        ],
        run: pass_through,
        resume: None,
        step: None,
    },
    NodeSpec {
        type_name: "telegram.send",
        label: "Telegram",
        group: NodeGroup::Communication,
        description: "Sends a message from your Telegram bot to a chat.",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[
            credential_param(&["telegram"]),
            ParamSpec::new(
                "chatId",
                "Chat ID",
                ParamKind::Text,
                Default::Text("{{ $json.chat.id }}"),
            ),
            ParamSpec::new("text", "Text", ParamKind::Text, Default::Text("")),
            ParamSpec::new(
                "parseMode",
                "Formatting",
                ParamKind::Select,
                Default::Text("none"),
            )
            .options(&["none", "MarkdownV2", "HTML"]),
            ParamSpec::new("file", "Photo or file", ParamKind::Text, Default::Text(""))
                .hint("e.g. {{ $json.file.path }}; the text becomes its caption"),
        ],
        run: run_telegram,
        resume: Some(resume_telegram),
        step: None,
    },
    NodeSpec {
        type_name: "discord.send",
        label: "Discord",
        group: NodeGroup::Communication,
        description: "Posts a message to a Discord channel through a webhook or a bot.",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[
            ParamSpec::new(
                "mode",
                "Send with",
                ParamKind::Select,
                Default::Text("webhook"),
            )
            .options(&["webhook", "bot"]),
            credential_param(&["discordWebhook", "discordBot"]),
            ParamSpec::new(
                "channelId",
                "Channel ID (bot)",
                ParamKind::Text,
                Default::Text(""),
            ),
            ParamSpec::new("content", "Message", ParamKind::Text, Default::Text("")),
            ParamSpec::new(
                "username",
                "Name shown (webhook)",
                ParamKind::Text,
                Default::Text(""),
            ),
            ParamSpec::new("file", "Attach a file", ParamKind::Text, Default::Text(""))
                .hint("e.g. {{ $json.file.path }}"),
        ],
        run: run_discord,
        resume: Some(resume_discord),
        step: None,
    },
];
