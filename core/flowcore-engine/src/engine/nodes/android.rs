//! Device nodes. Each asks the Android host for an effect and, where the
//! effect returns data, adds it to every item under a field.

use super::spec::{
    Default, NodeGroup, NodeResult, NodeRun, NodeSpec, ParamKind, ParamSpec, check_effect_error,
    resume_pass_through, with_field,
};
use crate::engine::context::Item;
use crate::errors::{ErrorKind, Result, fail};
use crate::value::{Obj, Val, get_key, obj};

fn send_sms(run: &NodeRun<'_>) -> Result<NodeResult> {
    let messages = (0..run.items().len())
        .map(|i| {
            let to = run.text("to", i)?;
            if to.is_empty() {
                return fail(ErrorKind::Node, "phone number is required");
            }
            Ok(Val::Obj(obj([
                ("to", Val::Str(to)),
                ("text", Val::Str(run.text("text", i)?)),
            ])))
        })
        .collect::<Result<Vec<_>>>()?;
    Ok(NodeResult::Effect(obj([
        ("type", "sms".into()),
        ("messages", Val::Arr(messages)),
    ])))
}

const fn field_param(fallback: &'static str) -> ParamSpec {
    ParamSpec::new(
        "field",
        "Output field",
        ParamKind::Text,
        Default::Text(fallback),
    )
}

/// Resume for read effects: the result's `keys` become a value stored on each item.
fn store_result(run: &NodeRun<'_>, result: &Obj, keys: &[&str]) -> Result<Vec<Vec<Item>>> {
    check_effect_error(result)?;
    let value = match keys {
        [key] => get_key(result, key).clone(),
        _ => Val::Obj(
            keys.iter()
                .map(|k| ((*k).to_owned(), get_key(result, k).clone()))
                .collect(),
        ),
    };
    Ok(vec![with_field(
        run.items(),
        &run.text("field", 0)?,
        &value,
    )])
}

fn effect(kind: &str) -> NodeResult {
    NodeResult::Effect(obj([("type", kind.into())]))
}

fn effect_with(kind: &str, key: &str, value: Val) -> NodeResult {
    NodeResult::Effect(obj([("type", kind.into()), (key, value)]))
}

fn notify(run: &NodeRun<'_>) -> Result<NodeResult> {
    let notifications = (0..run.items().len())
        .map(|i| {
            Ok(Val::Obj(obj([
                ("title", run.text("title", i)?.into()),
                ("body", run.text("body", i)?.into()),
            ])))
        })
        .collect::<Result<Vec<_>>>()?;
    Ok(effect_with(
        "notify",
        "notifications",
        Val::Arr(notifications),
    ))
}

const SPEAK_PROVIDERS: &[&str] = &["phone", "openai", "elevenlabs"];

/// The speak effect; fields at their defaults are left out, so the plain phone
/// voice stays `{ type, text }`.
fn speak(run: &NodeRun<'_>) -> Result<NodeResult> {
    let mut effect = obj([
        ("type", "speak".into()),
        ("text", run.text("text", 0)?.into()),
    ]);
    let provider = run.text("provider", 0)?;
    if !provider.is_empty() && provider != "phone" {
        if !SPEAK_PROVIDERS.contains(&provider.as_str()) {
            return fail(
                ErrorKind::Node,
                format!("unknown voice provider {provider}"),
            );
        }
        let credential = run.text("credential", 0)?;
        if credential.is_empty() {
            return fail(ErrorKind::Node, "choose a credential for the cloud voice");
        }
        effect.insert("provider".into(), provider.into());
        effect.insert("credential".into(), credential.into());
    }
    let voice = run.text("voice", 0)?;
    if !voice.is_empty() {
        effect.insert("voice".into(), voice.into());
    }
    let speed = run.number("speed", 0)?;
    #[allow(clippy::float_cmp)]
    if speed > 0.0 && speed != 1.0 {
        effect.insert("speed".into(), Val::Num(speed.clamp(0.25, 4.0)));
    }
    let style = run.text("style", 0)?;
    if !style.is_empty() {
        effect.insert("style".into(), style.into());
    }
    Ok(NodeResult::Effect(effect))
}

fn vibrate(run: &NodeRun<'_>) -> Result<NodeResult> {
    let ms = run.number("ms", 0)?;
    Ok(effect_with(
        "vibrate",
        "ms",
        Val::Num(if ms > 0.0 { ms } else { 0.0 }),
    ))
}

fn open_url(run: &NodeRun<'_>) -> Result<NodeResult> {
    Ok(effect_with("openUrl", "url", run.text("url", 0)?.into()))
}

fn clipboard_write(run: &NodeRun<'_>) -> Result<NodeResult> {
    Ok(effect_with(
        "clipboardWrite",
        "text",
        run.text("text", 0)?.into(),
    ))
}

pub static ANDROID_NODES: &[NodeSpec] = &[
    NodeSpec {
        type_name: "android.notify",
        label: "Show Notification",
        group: NodeGroup::Android,
        description: "Posts one notification per item.",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[
            ParamSpec::new(
                "title",
                "Title",
                ParamKind::Text,
                Default::Text("FlowDroid"),
            ),
            ParamSpec::new("body", "Message", ParamKind::Text, Default::Text("")),
        ],
        run: notify,
        resume: Some(resume_pass_through),
        step: None,
    },
    NodeSpec {
        type_name: "android.sms",
        label: "Send SMS",
        group: NodeGroup::Android,
        description: "Sends a text message per item from this phone (carrier rates apply).",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[
            ParamSpec::new(
                "to",
                "To (phone number)",
                ParamKind::Text,
                Default::Text(""),
            ),
            ParamSpec::new("text", "Message", ParamKind::Text, Default::Text("")),
        ],
        run: send_sms,
        resume: Some(resume_pass_through),
        step: None,
    },
    NodeSpec {
        type_name: "android.speak",
        label: "Speak Text",
        group: NodeGroup::Android,
        description: "Reads text aloud (first item) with a phone voice, or a natural cloud voice from OpenAI or ElevenLabs.",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[
            ParamSpec::new("text", "Text", ParamKind::Text, Default::Text("")),
            ParamSpec::new(
                "provider",
                "Voice from",
                ParamKind::Select,
                Default::Text("phone"),
            )
            .options(SPEAK_PROVIDERS),
            ParamSpec::new(
                "credential",
                "Credential",
                ParamKind::Credential,
                Default::Text(""),
            )
            .options(&["openai", "elevenlabs"])
            .hint("not needed for phone voices"),
            ParamSpec::new("voice", "Voice", ParamKind::Text, Default::Text(""))
                .hint("empty = default"),
            ParamSpec::new("speed", "Speed", ParamKind::Number, Default::Number(1.0))
                .hint("0.5 to 2"),
            ParamSpec::new(
                "style",
                "Speaking style",
                ParamKind::Text,
                Default::Text(""),
            )
            .hint("OpenAI only, e.g. calm and warm"),
        ],
        run: speak,
        resume: Some(resume_pass_through),
        step: None,
    },
    NodeSpec {
        type_name: "android.vibrate",
        label: "Vibrate",
        group: NodeGroup::Android,
        description: "Vibrates the device.",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[ParamSpec::new(
            "ms",
            "Duration (ms)",
            ParamKind::Number,
            Default::Number(500.0),
        )],
        run: vibrate,
        resume: Some(resume_pass_through),
        step: None,
    },
    NodeSpec {
        type_name: "android.openUrl",
        label: "Open URL",
        group: NodeGroup::Android,
        description: "Opens a link in the browser or the app that handles it (first item).",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[ParamSpec::new(
            "url",
            "URL",
            ParamKind::Text,
            Default::Text("https://"),
        )],
        run: open_url,
        resume: Some(resume_pass_through),
        step: None,
    },
    NodeSpec {
        type_name: "android.clipboardWrite",
        label: "Copy to Clipboard",
        group: NodeGroup::Android,
        description: "Copies text to the clipboard (first item).",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[ParamSpec::new(
            "text",
            "Text",
            ParamKind::Text,
            Default::Text(""),
        )],
        run: clipboard_write,
        resume: Some(resume_pass_through),
        step: None,
    },
    NodeSpec {
        type_name: "android.clipboardRead",
        label: "Read Clipboard",
        group: NodeGroup::Android,
        description: "Adds the clipboard text to every item.",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[field_param("clipboard")],
        run: |_| Ok(effect("clipboardRead")),
        resume: Some(|run, result| store_result(run, result, &["text"])),
        step: None,
    },
    NodeSpec {
        type_name: "android.battery",
        label: "Battery Status",
        group: NodeGroup::Android,
        description: "Adds the battery level (0-100) and charging state to every item.",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[field_param("battery")],
        run: |_| Ok(effect("battery")),
        resume: Some(|run, result| store_result(run, result, &["level", "charging"])),
        step: None,
    },
    NodeSpec {
        type_name: "android.location",
        label: "Get Location",
        group: NodeGroup::Android,
        description: "Adds the current GPS position to every item.",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[field_param("location")],
        run: |_| Ok(effect("location")),
        resume: Some(|run, result| {
            store_result(run, result, &["latitude", "longitude", "accuracy"])
        }),
        step: None,
    },
];
