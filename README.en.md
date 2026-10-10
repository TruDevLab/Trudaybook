# Trudaybook

[Русский](README.md) · **English** · [简体中文](README.zh.md)

Mail and calendar on one day timeline. Emails sit where they arrived,
meetings where they start, and everything you haven't handled piles up
in one list until you clear it.

![Day: emails and meetings on the timeline](docs/day-en.png)

**Everything stays on your Mac.** Mail comes straight from your mail
servers, passwords live in the macOS Keychain, and the app has no server
of its own. What goes out and where is listed [in its own section](#what-leaves-your-mac).

---

## Contents

- [How the day works](#how-the-day-works)
- [Week](#week)
- [Features](#features)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [What leaves your Mac](#what-leaves-your-mac)
- [Install](#install) · [Requirements](#requirements) ·
  [Limitations](#limitations) · [Development](#development)

---

## How the day works

An hour scale runs across the top. The upper lane holds emails, placed by
arrival time; close ones stack into a “+N” bundle. The lower lane holds
meetings as blocks as long as they last, and reminders with a “done” circle.

Drag anything onto **Archive**, **Reply** or **Snooze** — or straight onto
the timeline, to a new time. Handled items fade and get a checkmark.
Everything unhandled from all days waits at the bottom in **To handle**:
Inbox Zero. A snoozed email leaves that list and comes back at the hour
you chose.

On the right: the whole email or meeting — replies with formatting,
attachments, invitations with Accept and Decline, attendees and the online
meeting link.

The timeline can run top to bottom too — the button next to “Day | Week” —
or sit below the email list: drag it by the ≡ handle left of the date,
or press ⌥⌘B. Working hours are lighter; which hours
they are and how many hours you see at once (12 by default) — Settings →
Calendars → Timeline. A checkmark on an email or a bundle means handled;
a past meeting simply fades.

## Week

![Week](docs/week-en.png)

Days as columns, hours top to bottom. Above the calendar you choose what
it shows:

| Mode | On the calendar |
|---|---|
| **Events** | Meetings and reminders |
| **Emails** | Each day's emails by time |
| **Weather** | Hourly weather, blue for the chance of rain |

Next to it — **“5 days | 7 days”**. Each day's header shows the weather and
the count of unhandled emails. Meetings you haven't answered, or answered
“tentative”, are hatched and outlined with a dashed line.

![Hourly weather](docs/weather-en.png)

---

## Features

**Mail**
- iCloud, Gmail, Yandex, Mail.ru and any IMAP/SMTP server; corporate
  Exchange directly over EWS (NTLM sign-in). Several mailboxes at once.
- Mailbox folders with date sections. Search by subject, sender, recipients
  and Cc; the “From”, “To”, “Cc” buttons (or `from:`, `to:`, `cc:`) narrow it
  to one field; Return searches the full text on the server.
- Conversations: emails of one thread in a single expandable row (turn it on
  in Settings); archiving the first email archives the whole thread. Each row
  shows whether you are a recipient (“Me”, red if only you) or in Cc.
- Replies and new emails with formatting, quotes and attachments; recipients
  as chips with address book suggestions, Bcc on demand; a signature per mailbox.
- Priorities (yours and the sender's); swipe actions on list rows — which
  ones is up to you in Settings.
- Meeting invitations: a card with that day's calendar and answer buttons.
- Open an email in its own window (double-click in the list or ⌘O), side by
  side with others; `.eml` files from Finder open in the same kind of window.
- Save a whole email as an `.eml` file with a button (⇧⌘S) or drag it to Finder.
- Several emails at once: ⇧ for a range, ⌘ one by one; then archive them or
  move them to the mailbox Trash (⌫).
- Right-click an email, meeting or reminder for a menu of the main actions.
- Pick which toolbar buttons to show and in what order in Settings →
  Appearance; “New” sits on the right.

**Calendar**
- macOS calendars (iCloud, Google, Exchange via Internet Accounts) and
  Exchange directly.
- New meeting or email: drag “Create” from the toolbar onto the meetings lane
  (the meeting starts where you drop it) or onto the mail lane; or press and
  hold on an empty spot. While you drag a meeting you see where it will land;
  moving a meeting with attendees asks for confirmation first.
  An editor with repeat, attendees, location and a free/busy planner.
- Double-click a meeting to edit it — the editor is its own window you can
  move aside to keep the timeline in view.
- macOS reminders on the timeline, checked off with one click.
- The month title expands into the whole year by quarters, with week numbers;
  click a day to open it on the timeline.
- A note for every day under the month calendar, and in its own window (⌘J)
  with formatting, lists and checklists; notes for the week and the month.

**Menu bar** — an icon with today's date: the month with week numbers, the
day's meetings (the current or next one in focus — Return joins it) and a
“Join” button for online meetings. ⌃⌥⌘J from any app joins the current or
next meeting. Zoom, Teams and Telemost meetings open straight in their app if
it's installed (the link goes only to an app signed by that service); others
open in the browser. Turn it off in Settings → Calendars.

**Desktop widgets** — “Today” (upcoming meetings with a countdown, reminders,
weather) and “To Handle” (how many emails are waiting and which matter):
right-click the desktop → “Edit Widgets…”.

**Defaults** — make Trudaybook your default mail app (“send email” links open
a new message) and default calendar (`.ics` files open as a new event):
Settings → Mail and → Calendars. Weather without Trunook comes straight from
Open-Meteo, by city or by location.

**Notifications** — for new emails in macOS Notification Center; “Reply”
right in the notification sends the answer without opening the window.

**Look** — Liquid Glass on macOS 26, light and dark, calm gradients and
texture backgrounds, your own picture as a background. The Sky theme follows
the time of day and the weather: the moon in its phase and stars at night,
the sun, clouds, rain, snow, fog and storms by day; optionally the seasons:
falling leaves in autumn, frost on the glass in winter, trees in bloom in
spring, flowers in summer. Russian, English
and Chinese interface.

**Tutorial** — on first launch Trudaybook walks you through the essentials on
sample emails and meetings; skip it any time, take it again from Help →
Trudaybook Tutorial or Settings → Appearance.

**AI on this Mac** — through [Ollama](https://ollama.com) (free; Trudaybook
offers to install it and download a suitable model itself, Settings → AI):
- **assistant chat** (the “Assistant” button or ⌥⌘A): opens above the selected
  email or meeting, with a draggable divider between them; it starts with tiles
  of ready requests (My day, Awaiting reply, Summarize email, Meeting prep,
  Reminder…); conversations in tabs,
  questions about meetings, emails and the daily note, “what do I have today”,
  “what did Orlov write”; attach an email or a meeting (`/mail` or `/cal` plus words from the subject) or a file (an image too, if
  the model sees images) or dictate the question — speech is recognized on this
  Mac. A reminder, meeting, email or daily-note entry is only **suggested as a
  card** — you create and send it; the email opens in a separate window;
- above each email there's a collapsed “Summary” bar: expand it and the model
  summarizes the email; “To handle” gets labels — Important, Conversation,
  Notifications, Newsletters — with a filter (newsletters and notifications
  show up even without the model, from the email's headers);
- “Daily Agenda” in the note window: key items for the day, meetings with a
  Minutes section and emails from attendees, reminders, important emails;
  week and month summaries from your daily notes;
- “Prepare reply template” in the reply window: the model reads the email and
  the earlier conversation and drafts a reply that answers every question;
  it makes no decisions for you — those are left as [placeholders].

**Together with [Trunook](https://github.com/TruDevLab/Trunook)** — a MacBook
notch app by the same author (optional, all off by default):
- emails, invitations, upcoming meetings and snoozed emails coming back —
  as banners in the notch; an email can be read as a preview right there —
  Reply All, Archive, Forward, In 1 hour — and an invitation shows what it
  overlaps with;
- a Mail tile and emails on Trunook's day timeline;
- while a Trunook timer runs, Trudaybook stays quiet and then sends one
  summary notification;
- a shared day note;
- weather in the calendar and for the Sky theme comes from Trunook.

---

## Keyboard shortcuts

| Keys | Action |
|---|---|
| ⌘E | Archive |
| ⌘R / ⇧⌘R | Reply / reply all |
| ⌘S | Snooze or reschedule |
| ⌘D | Decline a meeting |
| ⌘1 ⌘2 ⌘3 / ⌘0 | High, medium, low priority / clear |
| ⌘T | Today |
| ⌘J | Note in a window |
| ⌃⌥⌘J | Join the current or next meeting (from any app) |
| ⌘[ / ⌘] | Previous / next day (week in week view) |
| ⌘= / ⌘− | Zoom in / out |
| ⌥⌘1 / ⌥⌘2 | Day / week |
| ⇧⌘H | Hide / show handled emails on the timeline |
| ⌥⌘L | Timeline top to bottom |
| ⌥⌘B | Timeline at the bottom of the window |
| ↑ ↓ | Neighbouring item |

---

## What leaves your Mac

- **Your mail servers** — only the ones you add: IMAP and SMTP (ports 993,
  465/587) or Exchange EWS (HTTPS).
- **Update check** — once a day, a request to `api.github.com` for the latest
  version, with the app's name and version in the header; a new version is
  downloaded from GitHub. Turn it off in Settings → Updates. The app connects
  nowhere else on its own: no analytics, no server of its own.
- **Remote images in emails** don't load until you click “Load” above the email —
  otherwise the sender would learn you opened the email. JavaScript in emails
  is always off.
- **Passwords** — in the macOS Keychain, never written to the log. The mail
  cache on disk is encrypted with a key kept in the Keychain.
- **Weather** comes from Trunook, if installed. Without it — only if you turn it
  on in Settings → Calendars → Weather: then the forecast is requested from
  Open-Meteo with coordinates rounded to about 10 km, or by city name.
- **Summaries, labels, agendas, week summaries, reply templates and the chat** come only
  from an Ollama model on this Mac (`127.0.0.1`); Ollama cloud models are never
  offered or used, so neither emails nor notes go anywhere. The only downloads
  are Ollama itself (ollama.com) and models — when you press the button.
- Trudaybook talks to Trunook only through files in `~/Library/Application Support`
  on the same Mac.

---

## Install

> **The app is signed with a self-made certificate:** the project has no paid
> Apple developer account. On someone else's Mac, Gatekeeper won't let it
> through by default. The reliable way is to build from source — a build
> signed with your own certificate raises no questions. If you install from
> the disk image, remove the quarantine afterwards with the command below.

**From source**

```bash
git clone https://github.com/TruDevLab/Trudaybook.git
cd Trudaybook
make cert      # your own signing certificate, once
make install   # build and put into Applications
```

**From the disk image** — download `Trudaybook-<version>.dmg` from the release
page, drag Trudaybook to Applications and remove the quarantine:

```bash
sudo xattr -r -c /Applications/Trudaybook.app
```

The image carries the same instructions in “Как установить.txt”. To check
the signature: `codesign --verify --deep --strict /Applications/Trudaybook.app`.

**Updates** arrive by themselves: once a day Trudaybook asks GitHub, downloads
a new version in the background and checks its signature — only a build
signed with the same certificate is installed. An “Update to …” button
appears in the window: click it and the app restarts as the new version,
with calendar and password access still granted. A build you signed with
your own certificate can't update this way — use `git pull` and `make install`.

With no mailbox connected, Trudaybook opens with sample emails and meetings,
so you can see how it works. Add mail in Settings → Mail.

---

## Requirements

- macOS 15 or later; Liquid Glass on macOS 26.
- The disk image is built for Apple silicon Macs. On an Intel Mac, build from
  source — the build targets your processor.
- To build: Command Line Tools with Swift 6 (`xcode-select --install`).
  Xcode isn't needed.
- For iCloud, Gmail, Yandex and Mail.ru — an app password, not your main
  account password.

## Limitations

- Not notarized — see the note above.
- Gmail and Microsoft 365 with OAuth sign-in aren't supported: only an app
  password (Gmail) or your own Exchange server with EWS.
- Someone else's meeting can't be moved — only the organizer can.
- You can't answer the organizer for a meeting from a macOS calendar:
  EventKit can't do that. Answer from the invitation email or in an Exchange
  calendar connected directly.

## Development

Architecture, build, tests and translation — see [DEVELOPMENT.md](DEVELOPMENT.md)
(in Russian).

Found a bug? [Open an issue](../../issues/new/choose) and attach
`~/Library/Logs/Trudaybook.log` with the addresses removed.

License — [MIT](LICENSE).
