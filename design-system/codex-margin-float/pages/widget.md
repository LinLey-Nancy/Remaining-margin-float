# Floating Widget Override

This file overrides `../MASTER.md` for the desktop floating widget.

## Intent

- Calm at-a-glance monitoring, not an alerting dashboard
- Quiet-luxury light surface with restrained depth
- Compact first; details appear only on click
- Information should feel reassuring even when quota is low

## Visual Tokens

| Role | Value |
|---|---|
| Surface | `#FCFBF8` warm ivory |
| Secondary surface | `#F5F4F0` |
| Primary text | `#343A35` |
| Secondary text | `#6B746D` |
| Muted text | `#8D958F` |
| Sage status | `#7E9584` |
| Sage wash | `#E9F0EA` |
| Champagne accent | `#BEA374` |
| Border | `#E8E4DC` |

Use Segoe UI Variable / Segoe UI / Microsoft YaHei UI from the operating
system. The widget must remain dependency-free and must not download fonts.

## Component Rules

- Window: 108×100 px compact / 370×500 px expanded
- Compact hierarchy: remaining percentage, period label, progress only
- Provider semantics: Codex shows quota percentage; DeepSeek shows currency
  balance unless the user explicitly sets a budget baseline. Never present a
  wallet balance as an inferred subscription quota.
- Detail hierarchy: account, four metric cards, token composition, freshness
- Hover: restrained sage halo plus a small elevation change; no scaling or jitter
- Base shadow: warm gray, 14 px blur, 2 px depth, 10% opacity
- Expansion: width and height switch atomically; detail content fades in over
  190 ms with the system reduced-motion preference respected
- Before expansion, fit the 370×500 detail surface inside the active monitor work
  area. Preserve the compact anchor and restore it after collapse.
- When the expanded window loses focus, collapse immediately to the compact
  size and restore its anchor. Ignore transient focus loss while the widget
  context menu is open.
- Drag threshold: 5 px so a click does not accidentally move the widget
- Missing Codex fields must say `未提供`; never synthesize quota data
- DeepSeek configuration uses a labeled native dialog, inline validation, and
  a clear cancel route. API keys must never be displayed in full.
- DeepSeek monthly spend must be labeled as a local estimate; never present
  locally reconstructed token cost as the authoritative account bill.
- Structural icons use WPF vector paths
- Exclude the floating surface from Win+Tab / Alt+Tab; expose a native Windows
  notification-area icon with labeled menu actions instead
- Tray icon: 32 px sage circle, ivory `C`, restrained champagne outline; no emoji

## Explicit Overrides

- Ignore the master recommendation for exaggerated, high-contrast typography.
- Ignore the master anti-pattern line about a light-mode default. This product
  intentionally uses light mode per the user requirement.
- No cyan CTA. Sage and champagne are the only accent families.
- No decorative chart. A single progress line is sufficient for this data.
