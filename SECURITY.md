# Security policy

FlowDroid runs on people's phones and can hold their API keys, read their
messages and act on their behalf, so security reports are taken seriously.

## Reporting a problem

Please **don't open a public issue** for a security problem. Instead, report it
privately through GitHub: on the repository's **Security** tab, choose
**Report a vulnerability**.

Include what an attacker could do, the steps to reproduce it, and the app
version. You'll get a reply as soon as possible, and credit in the fix if you
want it.

## What counts

Examples of things worth reporting:

- a way for another app, website or device to run a workflow, read
  credentials or read run history without permission;
- credentials ending up in logs, run history, backups or exported workflows
  in readable form;
- a webhook or MCP tool with a key set accepting requests without it.

Known, documented behavior, such as a webhook *without* a key accepting any
caller on the local network, is not a vulnerability. The
[known limits](docs/development.md#known-limits) list these.
