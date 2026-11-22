# Design

Direction: **Calm Clarity**, chosen 2026-11-21. FlowDroid should sit next to Things 3 in craft: light, airy, organized by white space, one blue for anything you can press, quiet but exact typography. It replaces the earlier stock Material 3 look.

## Principles

- White space organizes; lines and boxes are a last resort. Prefer spacing and alignment over borders and cards.
- One accent (blue) marks what can be pressed and what is running. Nothing decorative uses it.
- Color elsewhere is a code: each node group has one soft tint (icon tiles only), and run states have green, amber and red.
- Type does the hierarchy with few sizes and clear weight steps.
- Every state is visible: idle, running, succeeded, failed, disabled, empty.

## Typography

Inter (bundled, OFL) for everything; JetBrains Mono (bundled, OFL) for expressions, JSON and counts. Tabular figures for times and counts.

| Role | Size / weight | Use |
| --- | --- | --- |
| Large title | 28 / 700, tracking -2% | Screen titles (Workflows, workflow name) |
| Title | 20 / 600 | Sheet titles, node name in its sheet |
| Headline | 17 / 600 | List row titles |
| Body | 15 / 400, line 1.45 | Default text |
| Callout | 14 / 500 | Buttons in bars, labels beside switches |
| Caption | 13 / 400 | Secondary lines (grey) |
| Footnote | 12 / 600 | Section headings, field labels |
| Mono | 13 / 400 | Expressions, JSON, counts |

## Color

| Token | Light | Dark |
| --- | --- | --- |
| background | #FFFFFF | #111113 |
| canvas | #FAFAFB | #151517 |
| surface (nodes, sheets) | #FFFFFF | #1C1C1F |
| grouped (settings groups, inputs) | #F4F4F6 | #232327 |
| hairline | #ECECEF | #2A2A2E |
| text | #1C1C1E | #F2F2F4 |
| secondary text | #6E6E73 | #A1A1A8 |
| tertiary text | #8A8A8E | #7C7C84 |
| accent | #2F7CF6 | #4C8DFF |
| success | #2E9E52 | #4CC26E |
| warning | #E8920C | #F2A93B |
| danger | #E5484D | #FF6369 |

Group tints (icon color on a 14% tint): trigger amber, flow violet, data teal, network blue, android green, AI pink, communication indigo, database cyan, productivity red-orange, system graphite.

## Shape and depth

Radii: 9 (icon tiles), 12 (buttons, inputs), 14 (nodes, groups), 20 (sheets, dialogs). Depth is a soft two-layer shadow on nodes and floating controls only; everything else is flat.

## Spacing

4-pt base: 4, 8, 12, 16, 20, 24, 32. Screen gutter 20. Touch targets at least 44.

## Components

- **Bars:** no elevation, background-colored, hairline only where content scrolls under.
- **Bottom toolbar (editor):** icon buttons on the left, the blue Run pill on the right, all inside the bar.
- **Lists:** flat rows with an icon tile, a headline and a grey caption; inset hairline separators.
- **Status ring:** 22 px circle at the end of a node or run row: grey ring (idle), spinning blue arc (running), green ring with dot (succeeded), red ring with × (failed).
- **Inputs:** filled grouped background, no outline until focused (accent 1.5 px), label above the field.
- **Switches:** blue track when on, light grey when off, no outline.

## Motion

150–220 ms, ease-out. Press feedback is a subtle ripple; status rings animate their state change; nothing animates on scroll or page load.
