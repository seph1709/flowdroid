//! Phone productivity nodes: the phone's calendar and contacts, Ask Me, speech
//! to text, sound mode, alarms and timers, and photos. See `nodes/phone.ts`.

use super::spec::{
    Default, NodeGroup, NodeResult, NodeRun, NodeSpec, ParamKind, ParamSpec, check_effect_error,
    resume_pass_through, with_field,
};
use crate::engine::context::Item;
use crate::errors::{ErrorKind, Result, fail};
use crate::value::{Obj, Val, get_key, js_trim, obj, to_num};

const fn field_param(fallback: &'static str) -> ParamSpec {
    ParamSpec::new(
        "field",
        "Output field",
        ParamKind::Text,
        Default::Text(fallback),
    )
}

fn check_option(value: String, options: &[&str], what: &str) -> Result<String> {
    if !options.contains(&value.as_str()) {
        return fail(ErrorKind::Node, format!("unknown {what} {value}"));
    }
    Ok(value)
}

/// Each item with the host's per-item answer (`results[i]`) under the output field.
fn per_item_results(run: &NodeRun<'_>, result: &Obj) -> Result<Vec<Vec<Item>>> {
    check_effect_error(result)?;
    let Val::Arr(results) = get_key(result, "results") else {
        return fail(ErrorKind::Node, "the phone returned no result");
    };
    let field = run.text("field", 0)?;
    Ok(vec![
        run.items()
            .iter()
            .enumerate()
            .map(|(i, item)| {
                let mut copy = item.clone();
                copy.insert(field.clone(), results.get(i).cloned().unwrap_or(Val::Null));
                copy
            })
            .collect(),
    ])
}

/// Every item with the result's [keys] (one value, or an object of them) under the output field.
fn store_keys(run: &NodeRun<'_>, result: &Obj, keys: &[&str]) -> Result<Vec<Vec<Item>>> {
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

/// A list the host returned under [key], or an empty one.
fn list_of(result: &Obj, key: &str) -> Vec<Val> {
    match get_key(result, key) {
        Val::Arr(list) => list.clone(),
        _ => Vec::new(),
    }
}

fn strs(list: &[String]) -> Val {
    Val::Arr(list.iter().map(|s| Val::Str(s.clone())).collect())
}

// ---------------------------------------------------------------- times and days

/// `7:05` → `07:05`; fails unless it is a 24-hour time.
fn clock_time(text: &str, what: &str) -> Result<(u32, u32)> {
    let t = js_trim(text);
    let parsed = t.split_once(':').and_then(|(h, m)| {
        let digits = |s: &str, max: usize| {
            (!s.is_empty() && s.len() <= max && s.bytes().all(|b| b.is_ascii_digit()))
                .then(|| s.parse::<u32>().ok())
                .flatten()
        };
        Some((
            digits(h, 2)?,
            (m.len() == 2).then(|| digits(m, 2)).flatten()?,
        ))
    });
    match parsed {
        Some((hour, minute)) if hour <= 23 && minute <= 59 => Ok((hour, minute)),
        _ => fail(ErrorKind::Node, format!("{what} must be a time like 07:30")),
    }
}

fn clock_text(text: &str, what: &str) -> Result<String> {
    let (hour, minute) = clock_time(text, what)?;
    Ok(format!("{hour:02}:{minute:02}"))
}

const DAYS: &[&str] = &["sun", "mon", "tue", "wed", "thu", "fri", "sat"];

/// `Mon, wed` → `["mon", "wed"]`, in the order given, without repeats.
fn days(text: &str) -> Result<Vec<String>> {
    let mut out: Vec<String> = Vec::new();
    for part in text.split(',') {
        let day = js_trim(part);
        if day.is_empty() {
            continue;
        }
        let short: String = day.to_lowercase().chars().take(3).collect();
        if !DAYS.contains(&short.as_str()) {
            return fail(ErrorKind::Node, format!("unknown day {day}"));
        }
        if !out.contains(&short) {
            out.push(short);
        }
    }
    Ok(out)
}

// ---------------------------------------------------------------- calendar

const CALENDAR_OPERATIONS: &[&str] = &["list", "freeSlots", "create"];

fn calendar_run(run: &NodeRun<'_>) -> Result<NodeResult> {
    let operation = check_option(run.text("operation", 0)?, CALENDAR_OPERATIONS, "operation")?;
    if operation == "create" {
        let events = (0..run.items().len())
            .map(|i| {
                let title = run.text("title", i)?;
                if title.is_empty() {
                    return fail(ErrorKind::Node, "title is empty");
                }
                let start = run.text("start", i)?;
                if start.is_empty() {
                    return fail(ErrorKind::Node, "start is empty");
                }
                Ok(Val::Obj(obj([
                    ("title", Val::Str(title)),
                    ("start", Val::Str(start)),
                    ("end", Val::Str(run.text("end", i)?)),
                    ("allDay", Val::Bool(run.param("allDay").is_true())),
                    ("location", Val::Str(run.text("location", i)?)),
                    ("description", Val::Str(run.text("description", i)?)),
                    ("calendar", Val::Str(run.text("calendar", i)?)),
                ])))
            })
            .collect::<Result<Vec<_>>>()?;
        return Ok(NodeResult::Effect(obj([
            ("type", "calendar".into()),
            ("operation", Val::Str(operation)),
            ("events", Val::Arr(events)),
        ])));
    }
    let mut effect = obj([
        ("type", "calendar".into()),
        ("operation", Val::Str(operation.clone())),
        ("from", Val::Str(run.text("from", 0)?)),
        ("to", Val::Str(run.text("to", 0)?)),
        ("calendar", Val::Str(run.text("calendar", 0)?)),
    ]);
    if operation == "freeSlots" {
        let minutes = run.number("minutes", 0)?.trunc();
        effect.insert(
            "minutes".into(),
            Val::Num(if minutes >= 1.0 { minutes } else { 1.0 }),
        );
        effect.insert(
            "dayStart".into(),
            Val::Str(clock_text(&run.text("dayStart", 0)?, "day starts at")?),
        );
        effect.insert(
            "dayEnd".into(),
            Val::Str(clock_text(&run.text("dayEnd", 0)?, "day ends at")?),
        );
    }
    Ok(NodeResult::Effect(effect))
}

fn calendar_resume(run: &NodeRun<'_>, result: &Obj) -> Result<Vec<Vec<Item>>> {
    let operation = run.text("operation", 0)?;
    if operation == "create" {
        return per_item_results(run, result);
    }
    check_effect_error(result)?;
    let key = if operation == "freeSlots" {
        "slots"
    } else {
        "events"
    };
    Ok(vec![with_field(
        run.items(),
        &run.text("field", 0)?,
        &Val::Arr(list_of(result, key)),
    )])
}

// ---------------------------------------------------------------- ask

fn ask_run(run: &NodeRun<'_>) -> Result<NodeResult> {
    let question = run.text("question", 0)?;
    if question.is_empty() {
        return fail(ErrorKind::Node, "question is empty");
    }
    let buttons: Vec<String> = run
        .text("buttons", 0)?
        .split(',')
        .map(|b| js_trim(b).to_owned())
        .filter(|b| !b.is_empty())
        .collect();
    let reply = run.param("reply").is_true();
    if buttons.is_empty() && !reply {
        return fail(
            ErrorKind::Node,
            "add a button, or let the person type an answer",
        );
    }
    if buttons.len() > 3 {
        return fail(ErrorKind::Node, "a notification shows at most 3 buttons");
    }
    let minutes = to_num(&run.value("timeout", 0)?);
    Ok(NodeResult::Effect(obj([
        ("type", "ask".into()),
        ("title", Val::Str(run.text("title", 0)?)),
        ("question", Val::Str(question)),
        ("buttons", strs(&buttons)),
        ("reply", Val::Bool(reply)),
        (
            "timeoutMs",
            Val::Num((if minutes > 0.0 { minutes } else { 1.0 }) * 60000.0),
        ),
    ])))
}

fn ask_resume(run: &NodeRun<'_>, result: &Obj) -> Result<Vec<Vec<Item>>> {
    check_effect_error(result)?;
    let text = |key: &str| match get_key(result, key) {
        Val::Str(s) => s.clone(),
        _ => String::new(),
    };
    let answer = obj([
        ("button", Val::Str(text("button"))),
        ("text", Val::Str(text("text"))),
        ("timedOut", Val::Bool(get_key(result, "timedOut").is_true())),
    ]);
    Ok(vec![with_field(
        run.items(),
        &run.text("field", 0)?,
        &Val::Obj(answer),
    )])
}

// ---------------------------------------------------------------- speech and sound

fn listen_run(run: &NodeRun<'_>) -> Result<NodeResult> {
    let seconds = to_num(&run.value("seconds", 0)?);
    Ok(NodeResult::Effect(obj([
        ("type", "listen".into()),
        ("prompt", Val::Str(run.text("prompt", 0)?)),
        ("language", Val::Str(run.text("language", 0)?)),
        (
            "maxMs",
            Val::Num((if seconds > 0.0 { seconds } else { 1.0 }) * 1000.0),
        ),
    ])))
}

fn listen_resume(run: &NodeRun<'_>, result: &Obj) -> Result<Vec<Vec<Item>>> {
    store_keys(run, result, &["text", "confidence"])
}

const SOUND_MODES: &[&str] = &[
    "silent",
    "vibrate",
    "normal",
    "dndOn",
    "dndPriority",
    "dndAlarms",
    "dndOff",
    "read",
];

fn sound_run(run: &NodeRun<'_>) -> Result<NodeResult> {
    let mode = check_option(run.text("mode", 0)?, SOUND_MODES, "mode")?;
    Ok(NodeResult::Effect(obj([
        ("type", "soundMode".into()),
        ("mode", Val::Str(mode)),
    ])))
}

fn sound_resume(run: &NodeRun<'_>, result: &Obj) -> Result<Vec<Vec<Item>>> {
    store_keys(run, result, &["ringer", "dnd"])
}

// ---------------------------------------------------------------- contacts

const CONTACT_OPERATIONS: &[&str] = &["find", "add"];

fn contacts_run(run: &NodeRun<'_>) -> Result<NodeResult> {
    let operation = check_option(run.text("operation", 0)?, CONTACT_OPERATIONS, "operation")?;
    if operation == "add" {
        let contacts = (0..run.items().len())
            .map(|i| {
                let name = run.text("name", i)?;
                if name.is_empty() {
                    return fail(ErrorKind::Node, "name is empty");
                }
                Ok(Val::Obj(obj([
                    ("name", Val::Str(name)),
                    ("phone", Val::Str(run.text("phone", i)?)),
                    ("email", Val::Str(run.text("email", i)?)),
                ])))
            })
            .collect::<Result<Vec<_>>>()?;
        return Ok(NodeResult::Effect(obj([
            ("type", "contacts".into()),
            ("operation", Val::Str(operation)),
            ("contacts", Val::Arr(contacts)),
        ])));
    }
    let queries = (0..run.items().len())
        .map(|i| {
            let query = run.text("query", i)?;
            if query.is_empty() {
                return fail(ErrorKind::Node, "search for a name or a number");
            }
            Ok(Val::Str(query))
        })
        .collect::<Result<Vec<_>>>()?;
    let limit = run.number("limit", 0)?.trunc();
    Ok(NodeResult::Effect(obj([
        ("type", "contacts".into()),
        ("operation", Val::Str(operation)),
        ("queries", Val::Arr(queries)),
        ("limit", Val::Num(if limit >= 1.0 { limit } else { 1.0 })),
    ])))
}

// ---------------------------------------------------------------- clock

const CLOCK_OPERATIONS: &[&str] = &["alarm", "timer", "showAlarms"];

fn clock_run(run: &NodeRun<'_>) -> Result<NodeResult> {
    let operation = check_option(run.text("operation", 0)?, CLOCK_OPERATIONS, "operation")?;
    let label = run.text("label", 0)?;
    if operation == "showAlarms" {
        return Ok(NodeResult::Effect(obj([
            ("type", "clock".into()),
            ("operation", Val::Str(operation)),
        ])));
    }
    if operation == "alarm" {
        let (hour, minute) = clock_time(&run.text("time", 0)?, "time")?;
        let repeat = days(&run.text("days", 0)?)?;
        return Ok(NodeResult::Effect(obj([
            ("type", "clock".into()),
            ("operation", Val::Str(operation)),
            ("hour", Val::Num(f64::from(hour))),
            ("minute", Val::Num(f64::from(minute))),
            ("days", strs(&repeat)),
            ("label", Val::Str(label)),
        ])));
    }
    let seconds = run.number("seconds", 0)?.trunc();
    if seconds < 1.0 {
        return fail(ErrorKind::Node, "the timer needs at least 1 second");
    }
    Ok(NodeResult::Effect(obj([
        ("type", "clock".into()),
        ("operation", Val::Str(operation)),
        ("seconds", Val::Num(seconds)),
        ("label", Val::Str(label)),
    ])))
}

// ---------------------------------------------------------------- photos

const PHOTO_SOURCES: &[&str] = &["camera", "gallery", "scan"];

fn photo_run(run: &NodeRun<'_>) -> Result<NodeResult> {
    let source = check_option(run.text("source", 0)?, PHOTO_SOURCES, "source")?;
    let pages = run.number("pages", 0)?.trunc();
    // NaN stays NaN, as in the reference.
    let pages = pages.clamp(1.0, 20.0);
    Ok(NodeResult::Effect(obj([
        ("type", "photo".into()),
        ("source", Val::Str(source)),
        ("multiple", Val::Bool(run.param("multiple").is_true())),
        ("pages", Val::Num(pages)),
        ("pdf", Val::Bool(run.param("pdf").is_true())),
    ])))
}

/// Every item with `file` (the first photo or page), `files` (all of them) and, for a scan, `pdf`.
fn photo_resume(run: &NodeRun<'_>, result: &Obj) -> Result<Vec<Vec<Item>>> {
    check_effect_error(result)?;
    let files: Vec<Val> = list_of(result, "files")
        .into_iter()
        .filter(|f| matches!(f, Val::Obj(_)))
        .collect();
    let Some(first) = files.first().cloned() else {
        let message = if get_key(result, "cancelled").is_true() {
            "cancelled: no photo was taken"
        } else {
            "the phone returned no photo"
        };
        return fail(ErrorKind::Node, message);
    };
    let mut items = with_field(run.items(), "file", &first);
    items = with_field(&items, "files", &Val::Arr(files));
    let pdf = get_key(result, "pdf");
    if matches!(pdf, Val::Obj(_)) {
        items = with_field(&items, "pdf", pdf);
    }
    Ok(vec![items])
}

pub static PHONE_NODES: &[NodeSpec] = &[
    NodeSpec {
        type_name: "android.calendar",
        label: "Phone Calendar",
        group: NodeGroup::Android,
        description: "Lists events, finds free time, or adds events in the phone\u{2019}s own calendars (any account, no sign-in).",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[
            ParamSpec::new(
                "operation",
                "Operation",
                ParamKind::Select,
                Default::Text("list"),
            )
            .options(CALENDAR_OPERATIONS),
            ParamSpec::new("from", "From", ParamKind::Text, Default::Text(""))
                .hint("empty = start of today; a date and time, e.g. {{ $now }}"),
            ParamSpec::new("to", "To", ParamKind::Text, Default::Text(""))
                .hint("empty = the end of that day"),
            ParamSpec::new(
                "minutes",
                "Shortest free time (minutes)",
                ParamKind::Number,
                Default::Number(30.0),
            ),
            ParamSpec::new(
                "dayStart",
                "Day starts at",
                ParamKind::Text,
                Default::Text("08:00"),
            ),
            ParamSpec::new(
                "dayEnd",
                "Day ends at",
                ParamKind::Text,
                Default::Text("18:00"),
            ),
            ParamSpec::new("title", "Title", ParamKind::Text, Default::Text("")),
            ParamSpec::new("start", "Starts", ParamKind::Text, Default::Text(""))
                .hint("a date and time, e.g. 2026-11-24T15:00"),
            ParamSpec::new("end", "Ends", ParamKind::Text, Default::Text(""))
                .hint("empty = one hour later"),
            ParamSpec::new(
                "allDay",
                "All day",
                ParamKind::Boolean,
                Default::Bool(false),
            ),
            ParamSpec::new("location", "Location", ParamKind::Text, Default::Text("")),
            ParamSpec::new("description", "Notes", ParamKind::Text, Default::Text("")),
            ParamSpec::new("calendar", "Calendar", ParamKind::Text, Default::Text(""))
                .hint("part of its name; empty = all (new events: the main one)"),
            field_param("calendar"),
        ],
        run: calendar_run,
        resume: Some(calendar_resume),
        step: None,
    },
    NodeSpec {
        type_name: "android.ask",
        label: "Ask Me",
        group: NodeGroup::Android,
        description: "Shows a notification with buttons or a reply box, and waits for your answer.",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[
            ParamSpec::new(
                "title",
                "Title",
                ParamKind::Text,
                Default::Text("FlowDroid asks"),
            ),
            ParamSpec::new("question", "Question", ParamKind::Text, Default::Text("")),
            ParamSpec::new(
                "buttons",
                "Buttons",
                ParamKind::Text,
                Default::Text("Yes, No"),
            )
            .hint("comma separated, up to 3"),
            ParamSpec::new(
                "reply",
                "Let me type an answer",
                ParamKind::Boolean,
                Default::Bool(false),
            ),
            ParamSpec::new(
                "timeout",
                "Wait at most (minutes)",
                ParamKind::Number,
                Default::Number(60.0),
            ),
            field_param("answer"),
        ],
        run: ask_run,
        resume: Some(ask_resume),
        step: None,
    },
    NodeSpec {
        type_name: "android.listen",
        label: "Speech to Text",
        group: NodeGroup::Android,
        description: "Listens through the microphone and adds what you said as text.",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[
            ParamSpec::new(
                "prompt",
                "Prompt",
                ParamKind::Text,
                Default::Text("Speak now"),
            ),
            ParamSpec::new("language", "Language", ParamKind::Text, Default::Text(""))
                .hint("e.g. en-US; empty = the phone\u{2019}s language"),
            ParamSpec::new(
                "seconds",
                "Listen at most (seconds)",
                ParamKind::Number,
                Default::Number(30.0),
            ),
            field_param("speech"),
        ],
        run: listen_run,
        resume: Some(listen_resume),
        step: None,
    },
    NodeSpec {
        type_name: "android.sound",
        label: "Sound Mode",
        group: NodeGroup::Android,
        description: "Sets the ringer (silent, vibrate, normal) or Do Not Disturb; adds the mode it had before, so you can restore it.",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[
            ParamSpec::new("mode", "Set to", ParamKind::Select, Default::Text("silent"))
                .options(SOUND_MODES),
            field_param("sound"),
        ],
        run: sound_run,
        resume: Some(sound_resume),
        step: None,
    },
    NodeSpec {
        type_name: "android.contacts",
        label: "Contacts",
        group: NodeGroup::Android,
        description: "Finds contacts by name or number (one search per item), or adds new ones.",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[
            ParamSpec::new(
                "operation",
                "Operation",
                ParamKind::Select,
                Default::Text("find"),
            )
            .options(CONTACT_OPERATIONS),
            ParamSpec::new(
                "query",
                "Name or number",
                ParamKind::Text,
                Default::Text(""),
            ),
            ParamSpec::new(
                "limit",
                "Most results",
                ParamKind::Number,
                Default::Number(5.0),
            ),
            ParamSpec::new("name", "Name", ParamKind::Text, Default::Text("")),
            ParamSpec::new("phone", "Phone number", ParamKind::Text, Default::Text("")),
            ParamSpec::new("email", "Email", ParamKind::Text, Default::Text("")),
            field_param("contacts"),
        ],
        run: contacts_run,
        resume: Some(per_item_results),
        step: None,
    },
    NodeSpec {
        type_name: "android.clock",
        label: "Alarm & Timer",
        group: NodeGroup::Android,
        description: "Sets an alarm or starts a timer in the phone\u{2019}s clock app (first item).",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[
            ParamSpec::new(
                "operation",
                "Operation",
                ParamKind::Select,
                Default::Text("alarm"),
            )
            .options(CLOCK_OPERATIONS),
            ParamSpec::new("time", "Time", ParamKind::Text, Default::Text("07:00"))
                .hint("24-hour, e.g. 06:45"),
            ParamSpec::new("days", "Repeat on", ParamKind::Text, Default::Text(""))
                .hint("e.g. mon, tue, fri; empty = once"),
            ParamSpec::new(
                "seconds",
                "Timer length (seconds)",
                ParamKind::Number,
                Default::Number(300.0),
            ),
            ParamSpec::new("label", "Label", ParamKind::Text, Default::Text("")),
        ],
        run: clock_run,
        resume: Some(resume_pass_through),
        step: None,
    },
    NodeSpec {
        type_name: "android.photo",
        label: "Photo & Scan",
        group: NodeGroup::Android,
        description: "Takes a photo, picks photos from the gallery, or scans a document; adds them as files. Needs FlowDroid on screen.",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[
            ParamSpec::new("source", "From", ParamKind::Select, Default::Text("camera"))
                .options(PHOTO_SOURCES),
            ParamSpec::new(
                "multiple",
                "Pick several",
                ParamKind::Boolean,
                Default::Bool(false),
            ),
            ParamSpec::new(
                "pages",
                "Most pages",
                ParamKind::Number,
                Default::Number(5.0),
            ),
            ParamSpec::new(
                "pdf",
                "Also make a PDF",
                ParamKind::Boolean,
                Default::Bool(true),
            ),
        ],
        run: photo_run,
        resume: Some(photo_resume),
        step: None,
    },
];
