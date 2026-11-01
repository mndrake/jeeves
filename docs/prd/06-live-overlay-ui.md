# PRD 06 - Live Overlay UI

Milestone: M4. Status: v0.2 after interview (two-phase display confirmed).

## Problem
During a call the user's attention is on the other person's face and on their own
camera. The answer has to be glanceable in under a second, must not steal focus or
keyboard input from the call app, and must not appear in a shared screen.

## Goals
- A floating panel that shows the current question, the top matching passages **immediately**, and Claude's streaming answer below them, readable at arm's length, in light and dark mode.
- Never activates or takes keyboard focus; the call app stays frontmost.
- Hidden from screen sharing; the user is warned when sharing starts.
- Menu bar presence for state (idle, listening, answering) and session start/stop.

## Non-goals
- Full transcript editor; a simple scroll-back is enough.
- Second-device companion (iPhone/iPad) - revisit after the interview.

## Components
1. **Menu bar item**: icon reflects state; menu with Start/Stop listening, source app picker, mode (Auto/Assist/Manual), knowledge source filter, Settings, Quit.
2. **Overlay panel** (`NSPanel`, `.nonactivatingPanel`, `.floating` level, `collectionBehavior` includes `.canJoinAllSpaces` and `.fullScreenAuxiliary`, `sharingType = .none`):
   - Header: detected question (or "Listening..." with a level meter).
   - Passages block (phase 1): top 3 passages, each with breadcrumb (`Doc > Section`), the matched sentence highlighted, and a source chip; appears within ~300 ms of detection and never waits on the network.
   - Answer block (phase 2): streaming bullets with `[n]` citations that highlight the matching passage above on hover; shows a subtle "thinking" shimmer only in the gap between phases; shows "offline: passages only" or "Claude declined" states inline.
   - Footer: confidence indicator, "weak match" badge when applicable, model mode toggle (Fast / Default / Deep), quick actions (pin, more, shorter, copy, dismiss), a one-line typed-question field.
   - Opacity slider and compact/expanded toggle. Remembers position per display.
   - Click-through mode: panel ignores mouse events except on a small grip, so the user can keep interacting with the call window underneath.
3. **Transcript drawer**: optional slide-out with the last 5 minutes, colour-coded by channel; click a line to answer it.
4. **Assist chips**: in Assist mode, a small "?" chip appears on the detected question; click or hotkey answers.
5. **Share warning**: detect active screen sharing (ScreenCaptureKit stream presence or the call app's share indicator where observable) and show a banner "Overlay is hidden from the shared screen" or a stronger warning when it cannot be determined.

## Interaction and hotkeys (defaults, remappable)
- `⌥⌘J` answer last utterance. `⇧⌥⌘J` answer last 30 s. `⌥⌘H` hide/show overlay. `⌥⌘K` focus typed-question field. `Esc` in the field returns focus to the previous app.

## Accessibility and ergonomics
- Minimum 14 pt body text, high-contrast mode, respects Reduce Motion and Reduce Transparency.
- Panel defaults to the edge of the screen nearest the camera so eye movement looks natural.

## Non-functional
- Passages rendered within 50 ms of retrieval; first answer token within 50 ms of arrival; no layout jank while streaming (fixed-width panel, passages keep their position while the answer grows downward).
- Panel never appears in the app's own Dock icon or in Mission Control previews when hidden.

## Acceptance criteria
- With Chrome (Meet) frontmost, passages and answers stream into the panel and typing still goes to the Meet chat box.
- Screen-share a tab, a window and the full screen in Meet and Zoom web: the panel is not visible to the other side (verified from a second account).
- Full-screen Meet in Chrome: panel still visible.

## Open questions
- Preferred default position and size? (assume right edge, 380 pt wide)
- Should passages collapse automatically once the answer finishes? (assume no; they are the fast path)
