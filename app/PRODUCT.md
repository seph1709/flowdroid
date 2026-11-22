# Product

<!-- impeccable:product-schema 1 -->

## Platform

android

## Users

Two groups, served by one interface:

- **Tinkerers** who automate their own phone and are comfortable with `{{ expressions }}`, JSON and HTTP.
- **Everyday Android users** who want simple automations (a low-battery alert, a morning quote) without learning expressions.

The design is simple by default, with power features one level deeper.

## Product Purpose

FlowDroid builds and runs n8n-style automation workflows entirely on the phone: triggers, logic and actions connected on a canvas, with no server. Success means a workflow keeps running reliably in the background once it's switched on.

## Positioning

A workflow engine that lives on the device itself. Its webhook server, schedules and phone actions (notifications, battery, location, clipboard, speech) run locally, and its Rust core was checked case by case against a TypeScript reference.

## Operating Context

- Built on the phone, usually in short sessions: create from a template, tweak parameters, press Run, read each node's output.
- Runs unattended afterwards: schedules, webhooks from other devices on the network, the "Keep running" background service with its permanent notification.

## Capabilities and Constraints

- Node types come from the core's catalog (triggers, flow, data, network, Android); the UI renders parameters from that catalog.
- Expressions use `{{ }}` with `$json`, `$node`, `$vars`, `$now` and a live preview against the last run.
- Execution history keeps the last 50 runs per workflow.
- Built with Flutter (Material components available via `package:material_ui`).

## Brand Commitments

- The name **FlowDroid** is final.
- Requested direction (user, 2026-11-21): minimalistic, clean and organized, including the typography; it should not look like a stock native Material app.

## Evidence on Hand

Four starter templates in `lib/data/templates.dart`. There are no screenshots, testimonials or usage numbers to show, and none may be invented.

## Product Principles

1. Simple by default, power one level deeper.
2. Make running state obvious: what is active, what ran, what failed, and why.
3. Show real data from the last run wherever a value is configured.
4. Background reliability over cleverness.
