# Design

Direction: **Clean Cards**, chosen 2026-11-25. It follows modern task-manager apps: a soft grey page with white cards on it, thin borders, small corner radii, compact Inter type, pastel tags and one blue for anything you can press. It replaced the earlier "Calm Clarity" look of white pages with grey groups.

## Principles

- White cards with a hairline border sit on a soft grey page. Sheets and dialogs are white.
- One accent (blue) marks what can be pressed, what is selected and what is running. Nothing decorative uses it.
- Color elsewhere is a code: each node group has one color, shown as an icon on a light tint of that color and as tags. Run states use green, amber and red.
- Type does the hierarchy with few sizes and clear weight steps. Text is compact, 14 px by default.
- Corners are small and consistent. Nothing is a pill.
- Every state is visible: idle, running, succeeded, failed, disabled, empty.

## Typography

Inter (bundled, OFL) for everything; JetBrains Mono (bundled, OFL) for expressions, JSON and counts.

| Role | Size / weight | Use |
| --- | --- | --- |
| Large title | 24 / 600, tracking -0.5 | Screen titles (Workflows, workflow name) |
| Title | 19 / 600 | Sheet titles, node name in its sheet |
| Headline | 15.5 / 600 | Card and list row titles |
| Body | 14 / 400, line 1.45 | Default text |
| Label | 14 / 600 | Buttons, tabs |
| Caption | 12.5 / 400 | Secondary lines (grey) |
| Section | 11 / 600, uppercase, tracking 0.5 | Section headings |
| Mono | 13 / 400 | Expressions, JSON, counts |

## Color

| Token | Light | Dark |
| --- | --- | --- |
| background (page, canvas) | #F4F4F5 | #0E0E10 |
| surface (cards, sheets, inputs) | #FFFFFF | #18181B |
| grouped (tracks, soft fills) | #F1F1F3 | #222226 |
| hairline (card borders, dividers) | #E7E7EA | #29292E |
| outline (input and button borders) | #DCDCE0 | #36363C |
| text | #18181B | #F2F2F4 |
| secondary text | #6B6B73 | #A1A1A8 |
| tertiary text | #9A9AA2 | #7C7C84 |
| accent | #2F7CF6 | #4C8DFF |
| success | #2E9E52 | #4CC26E |
| warning | #E8920C | #F2A93B |
| danger | #E5484D | #FF6369 |

Group colors: trigger amber, flow violet, data teal, network blue, android green, AI pink, communication indigo, database cyan, productivity red-orange, system graphite. Each has a light and a lighter dark-mode value (`AppColors.groups`). They appear as an icon on a 10% tint of the color (`IconTile`) and as tags (`Tag`). On the home list, the trigger's color goes grey while a workflow is switched off.

The launcher icon and splash follow the phone's dark mode: blue icon with a white mark in light mode, near-black with a blue mark in dark mode (`values-night/colors.xml`).

## Shape and depth

Radii (`Radii`): 6 for tags, 10 for buttons, inputs and small tiles, 12 for cards, canvas steps and menus, 16 for sheets and dialogs. Cards (`AppColors.card()`) have a hairline border and a barely visible shadow; nothing else has elevation.

## Spacing

4-pt base: 4, 8, 12, 16, 20, 24, 32. Screen gutter 20, card gutter 16, 8 between cards. Touch targets at least 44.

## Components

- **Cards:** white, hairline border, radius 12. The home list is one card per workflow: an icon tile in the trigger's color, the name, tags for the trigger and step count, and when it last ran.
- **Tags:** text in a group or state color on a 10% tint of it, radius 6, 11.5 px.
- **Icon tiles:** a glyph on a tinted square, used for steps, workflows and menu rows.
- **Bars:** no elevation, page-colored, hairline only where content scrolls under.
- **Buttons:** filled blue or white outlined, radius 10, 42 px tall. "New workflow" is a labeled button, not a round icon.
- **Tabs:** blue label and 2 px blue underline for the selected tab, grey for the rest.
- **Status ring:** 20–22 px circle at the end of a step or run row: grey ring (idle), spinning blue arc (running), green ring with dot (succeeded), red ring with × (failed).
- **Inputs:** white with a 1 px border, radius 10, accent border when focused, label above the field.
- **Switches:** blue track when on, light grey when off.
- **Canvas:** flat page grey with a faint dot grid; steps are white cards.

## Motion

150–220 ms, ease-out. Press feedback is a subtle ripple; status rings animate their state change; nothing animates on scroll or page load.
