//! Trigger nodes start an execution; the host decides when they fire and
//! passes their items to `start_execution`. Inside a run they pass items on.

use super::integrations::api::credential_param;
use super::spec::{Default, NodeGroup, NodeSpec, ParamKind, ParamSpec, pass_through};

/// A trigger the host fires; inside a run it passes its items on.
const fn trigger(
    type_name: &'static str,
    label: &'static str,
    description: &'static str,
    params: &'static [ParamSpec],
) -> NodeSpec {
    NodeSpec {
        type_name,
        label,
        group: NodeGroup::Trigger,
        description,
        inputs: 0,
        outputs: Some(&["main"]),
        params,
        run: pass_through,
        resume: None,
        step: None,
    }
}

/// Phone events the Phone Event trigger can wait for.
pub const PHONE_EVENTS: &[&str] = &[
    "powerConnected",
    "powerDisconnected",
    "batteryLow",
    "wifiConnected",
    "wifiDisconnected",
    "screenOn",
    "screenOff",
    "boot",
];

pub static TRIGGER_NODES: &[NodeSpec] = &[
    NodeSpec {
        type_name: "trigger.manual",
        label: "Manual Trigger",
        group: NodeGroup::Trigger,
        description: "Runs the workflow when you tap Run.",
        inputs: 0,
        outputs: Some(&["main"]),
        params: &[],
        run: pass_through,
        resume: None,
        step: None,
    },
    NodeSpec {
        type_name: "trigger.schedule",
        label: "Schedule Trigger",
        group: NodeGroup::Trigger,
        description: "Runs on a cron schedule, or every N minutes (Android runs periodic work at most every 15 minutes).",
        inputs: 0,
        outputs: Some(&["main"]),
        params: &[
            ParamSpec::new("mode", "Mode", ParamKind::Select, Default::Text("interval"))
                .options(&["interval", "cron"]),
            ParamSpec::new(
                "minutes",
                "Every (minutes)",
                ParamKind::Number,
                Default::Number(15.0),
            ),
            ParamSpec::new(
                "cron",
                "Cron expression",
                ParamKind::Text,
                Default::Text("0 9 * * *"),
            )
            .hint("minute hour day month weekday"),
        ],
        run: pass_through,
        resume: None,
        step: None,
    },
    NodeSpec {
        type_name: "trigger.webhook",
        label: "Webhook Trigger",
        group: NodeGroup::Trigger,
        description: "Runs when an HTTP request reaches the on-device server at /webhook/<path>.",
        inputs: 0,
        outputs: Some(&["main"]),
        params: &[
            ParamSpec::new("path", "Path", ParamKind::Text, Default::Text("my-hook")),
            ParamSpec::new("method", "Method", ParamKind::Select, Default::Text("POST"))
                .options(&["GET", "POST", "PUT", "DELETE", "ANY"]),
            ParamSpec {
                label: "Require a key",
                hint: Some("empty = anyone on the network can call it"),
                ..credential_param(&["webhookAuth"])
            },
        ],
        run: pass_through,
        resume: None,
        step: None,
    },
    trigger(
        "trigger.subworkflow",
        "When Called by a Workflow",
        "Runs when another workflow’s Execute Workflow node calls this one, with its items.",
        &[],
    ),
    trigger(
        "trigger.error",
        "Error Trigger",
        "Runs when a workflow that names this one as its error workflow fails.",
        &[],
    ),
    trigger(
        "trigger.sms",
        "SMS Trigger",
        "Runs for each SMS the phone receives (while FlowDroid runs).",
        &[
            ParamSpec::new("from", "Only from", ParamKind::Text, Default::Text(""))
                .hint("number, or part of it; empty = anyone"),
            ParamSpec::new(
                "contains",
                "Only if the text contains",
                ParamKind::Text,
                Default::Text(""),
            ),
        ],
    ),
    trigger(
        "trigger.notification",
        "Notification Trigger",
        "Runs when another app shows a notification (needs notification access).",
        &[
            ParamSpec::new("app", "Only from app", ParamKind::Text, Default::Text(""))
                .hint("app name or package, e.g. whatsapp"),
            ParamSpec::new(
                "contains",
                "Only if the text contains",
                ParamKind::Text,
                Default::Text(""),
            ),
        ],
    ),
    trigger(
        "trigger.phone",
        "Phone Event Trigger",
        "Runs when the phone is plugged in, Wi-Fi connects, the screen turns on, and more.",
        &[ParamSpec::new(
            "event",
            "Event",
            ParamKind::Select,
            Default::Text("powerConnected"),
        )
        .options(PHONE_EVENTS)],
    ),
    trigger(
        "trigger.place",
        "Place Trigger",
        "Runs when you arrive at or leave a place (checked every minute; needs location “all the time”).",
        &[
            ParamSpec::new(
                "latitude",
                "Latitude",
                ParamKind::Number,
                Default::Number(0.0),
            ),
            ParamSpec::new(
                "longitude",
                "Longitude",
                ParamKind::Number,
                Default::Number(0.0),
            ),
            ParamSpec::new(
                "radius",
                "Radius (meters)",
                ParamKind::Number,
                Default::Number(200.0),
            ),
            ParamSpec::new("event", "When I", ParamKind::Select, Default::Text("enter"))
                .options(&["enter", "leave"]),
        ],
    ),
    trigger(
        "trigger.share",
        "Share Trigger",
        "Runs when you share text, a link or a file to FlowDroid from another app.",
        &[],
    ),
    trigger(
        "trigger.tile",
        "Quick Tile Trigger",
        "Runs when you tap the FlowDroid tile in Quick Settings.",
        &[],
    ),
    trigger(
        "trigger.rss",
        "RSS Trigger",
        "Runs once for each new post in a feed.",
        &[
            ParamSpec::new("url", "Feed URL", ParamKind::Text, Default::Text("")),
            ParamSpec::new(
                "minutes",
                "Check every (minutes)",
                ParamKind::Number,
                Default::Number(15.0),
            ),
        ],
    ),
    trigger(
        "trigger.email",
        "Email Trigger (IMAP)",
        "Runs once for each new email in a mailbox.",
        &[
            credential_param(&["email"]),
            ParamSpec::new(
                "mailbox",
                "Mailbox",
                ParamKind::Text,
                Default::Text("INBOX"),
            ),
            ParamSpec::new(
                "minutes",
                "Check every (minutes)",
                ParamKind::Number,
                Default::Number(5.0),
            ),
        ],
    ),
];
