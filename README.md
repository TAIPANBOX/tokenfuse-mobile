<div align="center">

<img src="assets/logo.png" width="84" alt="TokenFuse">

# TokenFuse for iPhone & Apple Watch

### Hold the breaker on your agents.

Watch your AI agents' spend live, and pull a **hardware-signed kill switch** — from your pocket or your wrist.

![iOS](https://img.shields.io/badge/iOS-17.2+-000000?logo=apple)
![watchOS](https://img.shields.io/badge/watchOS-10+-000000?logo=apple)
![SwiftUI](https://img.shields.io/badge/SwiftUI-Swift%206-F05138?logo=swift&logoColor=white)
![license](https://img.shields.io/badge/license-Apache--2.0-blue)

</div>

---

This is the native **iPhone + Apple Watch** app for **[TokenFuse](https://github.com/TAIPANBOX/tokenfuse)** — a gateway that keeps AI agents from burning through your budget. The gateway does the enforcing; this app is the **command deck** you carry: see every agent's burn rate live, get alerted the moment one runs hot, and stop it with a kill that's *cryptographically signed on your device*.

<div align="center">

<table>
<tr>
<td width="25%"><img src="screenshots/pair.png" alt="Pair screen"></td>
<td width="25%"><img src="screenshots/runs.png" alt="Live fleet"></td>
<td width="25%"><img src="screenshots/run-detail.png" alt="Run detail with burn chart"></td>
<td width="25%"><img src="screenshots/dynamic-island.png" alt="Burn rate in the Dynamic Island"></td>
</tr>
<tr>
<td align="center"><sub>Pair once · key in the Enclave</sub></td>
<td align="center"><sub>Fleet burn rate, live</sub></td>
<td align="center"><sub>Burn chart · slide-to-arm kill</sub></td>
<td align="center"><sub>Dynamic Island</sub></td>
</tr>
</table>

</div>

---

## 🤔 What is this, in plain words?

A chatbot makes **one** call to an AI model. An **agent** makes *hundreds* — it thinks, calls a tool, reads the result, thinks again, and loops. That loop is what makes agents useful, and it's also what makes them dangerous: a stuck agent keeps calling the model, and the meter keeps spinning. Nothing looks broken — it still returns `200 OK` — so the **bill is often the first sign something went wrong**, and by then the money is gone.

**[TokenFuse](https://github.com/TAIPANBOX/tokenfuse)** is a small proxy you put between your agents and their AI provider. It adds up the real cost of every call as it happens and, the instant an agent blows past its budget, it cuts the circuit — before the damage lands.

**This app is the human in that loop.** You can't stare at a dashboard all day, and when something goes wrong you want to stop it *right now*, from wherever you are. So the app puts the whole fleet on your **iPhone** and your **Apple Watch**:

- **See** every agent's spend and burn rate, live.
- **Get alerted** the moment one runs hot.
- **Kill** a runaway agent in two taps — and that kill is signed by a key that lives in your device's **Secure Enclave**, so it can't be forged.

You don't need to be an engineer to use it: pair once, and the fleet is right there — green while you're safe, warming to amber, red when an agent is over budget.

---

## 🔒 Why a kill switch needs an app (and a signature)

Stopping an agent mid-task is a powerful, destructive action — so it has to be **authenticated**. If a kill were just an API call with a token, then anyone who stole that token could shut your agents down.

TokenFuse solves this with **hardware-backed signing**. When you pair this app, it generates a private key **inside the device's Secure Enclave** — a chip that never lets the key out, not even to the app itself. Every kill (and every budget change) is signed by that key on-device. The gateway verifies the signature before it acts. The result:

- A stolen **API token alone can't stop your agents** — it isn't the signing key.
- A stolen **phone can't fire the kill** either — the slide-to-arm control is behind **Face ID**.
- The kill is **enforced across every gateway** in your fleet, instantly.

This is the heart of the design: *the breaker is in your hand, and only your hand can pull it.*

---

## ✨ What it does

### 📱 iPhone

- **Live fleet** — every run with its spend and **burn rate** (`$/min`), sorted hottest-first, over-budget runs in red.
- **The fuse** — a signature burn meter that heats **mint → amber → ember** as spend approaches the cap. One glance tells you who's in trouble.
- **Run detail** — a **burn chart** for the last hour, plus steps / calls / cache-hits.
- **Slide-to-arm kill** — a deliberate, two-step control behind **Face ID**, signed by the Secure Enclave.
- **Per-run budgets** — set or change a run's cap right from your phone.
- **Dynamic Island & Lock Screen** — the burn rate rides along while you do other things (a **Live Activity**).
- **Notifications** — a nudge the moment a run crosses its cap.

### ⌚ Apple Watch

- **Fleet glance** — the fleet burn rate and every run as a fuse, on your wrist.
- **Kill from the wrist** — tap a run, tap **Kill**. The kill is *signed on the Apple Watch* by its own device key.
- **Face complication** — the burn rate rides on your **watch face**, amber normally and red when a run is over cap. No app to open.

<div align="center">

<table>
<tr>
<td width="33%"><img src="screenshots/watch-fleet.png" alt="Fleet on the wrist"></td>
<td width="33%"><img src="screenshots/watch-kill.png" alt="Kill from the wrist"></td>
<td width="33%"><img src="screenshots/watch-killed.png" alt="Killed"></td>
</tr>
<tr>
<td align="center"><sub>Fleet burn rate</sub></td>
<td align="center"><sub>Signed on the Apple Watch</sub></td>
<td align="center"><sub>Killed</sub></td>
</tr>
</table>

</div>

---

## 🎨 One identity — *the fuse*

Everything you see is built around a single idea: **a fuse that carries current until it must break the circuit.** The same visual language runs across the iPhone, the Apple Watch, and the [web dashboard](https://github.com/TAIPANBOX/tokenfuse/tree/main/cloud/dashboard) — so the tool feels like one product, not three.

| Colour | Meaning |
|---|---|
| 🟢 **Mint** | Within budget — all good. |
| 🟡 **Amber** | Warming — nearing the cap. |
| 🔴 **Ember** | Over cap, or the kill. |

The mark itself — an amber→ember tile with a black-keyline bolt — is the app icon, the pairing screen's emblem, and the dashboard's logo, all the same. Interactive design mockups live in [`design/`](design/) (open the `.html` files in a browser).

---

## 🚀 Build & run

You **don't need a paid Apple Developer account** to try it — it runs in the Simulator, or on a real device with a free Apple ID. (Only real remote push delivery and the App Store need the paid account.)

**Requirements:** macOS with **Xcode**, and **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** (the Xcode project is generated from [`ios/project.yml`](ios/project.yml), so it stays reviewable as text and is never committed).

```bash
brew install xcodegen
cd ios
xcodegen generate
open TokenFuse.xcodeproj
```

Then pick a scheme and run:

- **`TokenFuse`** — the iPhone app (embeds the widget for the Dynamic Island).
- **`TokenFuseWatch`** — the Apple Watch app (embeds the face complication).

On first launch you **pair** the app to a TokenFuse **plane** (the control-plane server) with a one-time code. To spin up a plane locally, see the [main TokenFuse repo](https://github.com/TAIPANBOX/tokenfuse) — in short, `cd cloud && docker compose up`, then create a pairing code from the dashboard.

---

## 🏗️ Architecture

A single SwiftUI codebase, shared across phone and watch.

- **SwiftUI · Swift 6** with strict concurrency; `@Observable` state, **SwiftData** for an offline cache, **Swift Charts** for the burn history.
- **WidgetKit** — the Dynamic Island / Lock-Screen **Live Activity** on iPhone, and the **watch-face complication** (fed from the app over an App Group).
- **CryptoKit / Secure Enclave** — device pairing and **ES256-signed** kills / budget changes. The exact wire protocol (canonical signing string, key formats) mirrors the gateway's, so a kill signed here is verified there.
- **Generated API layer** — the typed client mirrors [`ios/openapi.json`](ios/openapi.json), the same OpenAPI contract the control plane publishes.
- **XcodeGen** — the project is defined in YAML, not a binary `.pbxproj`, so changes are readable in a diff.

The iPhone and Apple Watch apps share the design system, the API layer, and the signing code; each adds only its own screens.

---

## 📊 Status

- **iPhone app — complete.** Pairing, live fleet, run detail with burn charts, Face-ID + Enclave-signed kill and budgets, notifications, Dynamic Island / Live Activity, app icon.
- **Apple Watch app — complete.** Live fleet, wrist-signed kill, and the face complication.
- **Deferred** (need a paid Apple Developer account or real paired devices): real remote **push** delivery, an **App Store** release, and hand-off of the session from the paired iPhone to the Watch over WatchConnectivity (today the Watch pairs on its own).

It has **not** had a production hardening pass or a security review — treat it as an early, capable app you can build and evaluate today.

---

## 🔗 Links

- **[TokenFuse](https://github.com/TAIPANBOX/tokenfuse)** — the gateway + Cloud control plane this app talks to.
- **[Web dashboard](https://github.com/TAIPANBOX/tokenfuse/tree/main/cloud/dashboard)** — the same fleet, the same *fuse*, in a browser.
- **[Mobile plan & wire protocol](https://github.com/TAIPANBOX/tokenfuse/blob/main/docs/14-mobile-companion.md)** · **[Design system](https://github.com/TAIPANBOX/tokenfuse/blob/main/docs/16-design-system.md)**
- **[`design/`](design/)** — interactive iPhone / Watch / dashboard mockups.

---

## 📄 License

[Apache-2.0](LICENSE).
