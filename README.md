# Learning Coach: Goal to Progress Tracking

A Telegram bot built with n8n. You tell it what you want to learn. It breaks the goal into skills, builds a roadmap, finds working resources, sends a short session every morning, quizzes you, and tracks your progress.

```
Goal → Skill Breakdown → Roadmap → Resources → Daily Tasks → Quiz → Evaluation → Progress
```

## Features

- **Goal planning:** `/goal learn SQL for data analysis` runs three LLM stages: skill breakdown, learning roadmap, and resources. A Code node validates each stage's output before the next one runs.
- **Checked resource links:** every link gets an HTTP `HEAD` request. Dead or missing links are replaced with a search link, so learners never get an invented URL.
- **Daily sessions:** sent every morning to each active learner, or on `/today`. If a session is still open, the same tasks are re-sent instead of new ones being generated. After a failed quiz, the topic is taught again from a different angle.
- **Quizzes:** `/done` creates multiple-choice questions on that day's tasks, one message per question with A–D buttons. The correct answers stay in Firestore and the buttons only carry indexes, so nobody can read the answers from the buttons.
- **Grading in code:** each answer is graded instantly by code, with no LLM call. After the last answer the quiz is scored once (a Firestore lock prevents double scoring), and the LLM explains the mistakes.
- **Progress tracking:** mastery per skill, streaks and scores. Available any time with `/progress`, and sent as a weekly report every Sunday at 18:00.
- **Optional email and calendar:** session emails through Gmail, and study blocks in Google Calendar.
- **Allow-list:** only the Telegram chat IDs you configure can use the bot.

## Bot commands

| Command | What it does |
|---|---|
| `/start`, `/help` | Show the welcome message and the command list |
| `/goal <what you want to learn>` | Create skills, a roadmap and resources |
| `/today` | Get the tasks for the current session |
| `/done` | Finished the tasks? Take the quiz |
| `/progress` | See streak, scores and skill mastery |
| `/roadmap` | See the full plan |
| `/email you@example.com` | Also receive sessions by email |
| `/time 19:00` | Set when study time is blocked in your calendar |
| `/pause`, `/resume` | Stop or restart the daily messages |

## How it works

There are three triggers: Telegram messages, a daily schedule (07:00) and a weekly schedule (Sunday 18:00). They all feed one pipeline:

1. **Intake:** *Parse Update* checks the allow-list. *Context* builds one item per learner (and creates new users). *Attach Goal* loads the active goal. *Route Action* sends the run to the right stage.
2. **Goal → Skills → Roadmap → Resources:** three LLM stages, each followed by validation, then the link check.
3. **Daily tasks:** one session per day, re-sent unchanged while still open.
4. **Quiz → Evaluation:** buttons are graded in code; scoring is protected by a lock; the LLM writes the feedback.
5. **Progress:** the quiz result, day log and goal state (mastery, streak, next session) are written to Firestore.

One Gemini chat model node serves all six LLM stages. To switch to another provider (OpenAI, Groq, Ollama…), replace that single node.

### Firestore data model

```
users/{telegram_user_id}
  ├── goals/{goal_id}        goal, skills, roadmap, resources, mastery, streak
  ├── days/{date}            daily session log
  ├── quizzes/{quiz_id}      questions, answers, score
  └── locks/{id}             makes sure each quiz is evaluated only once
```

## Tech stack

- [n8n](https://n8n.io) for workflow automation (tested on 2.26)
- Telegram Bot API (trigger and replies)
- Google Gemini (`gemini-flash-latest`) through n8n's LangChain nodes
- Google Cloud Firestore, as the database
- Gmail and Google Calendar (optional)

## Setup

### 1. Prerequisites

- Node.js 22 LTS and n8n, installed with `npm install -g n8n` (or Docker)
- cloudflared, to get a public HTTPS URL when n8n runs on your PC (see [step 5](#5-run-n8n-on-your-pc-with-a-cloudflare-tunnel-windows))
- A Telegram bot token from [@BotFather](https://t.me/BotFather)
- A Google Cloud / Firebase project with a **Firestore database in Native mode, with the ID `(default)`**
- A Google service account that has the **Cloud Datastore User** role on that project, plus its JSON key
- A Gemini API key from [Google AI Studio](https://aistudio.google.com/apikey)

### 2. Import the workflow

In n8n, go to **Workflows → Import from file** and choose [`workflow/learning-coach.json`](workflow/learning-coach.json).

### 3. Create the credentials

| n8n credential | Used by |
|---|---|
| Telegram API | Telegram Trigger and the reply nodes |
| Google Service Account (Google API) | All Firestore nodes |
| Google Gemini (PaLM) API | Gemini Model |
| Gmail OAuth2 *(optional)* | Send Email (disabled by default) |
| Google Calendar OAuth2 *(optional)* | Create Study Event (disabled by default) |

Open each node that shows a credential warning and select the credential you created.

### 4. Edit the `Config` node

| Field | Set it to |
|---|---|
| `firebaseProjectId` | Your Firebase project ID (not its display name) |
| `ownerChatId` | Your Telegram chat ID (send a message to [@userinfobot](https://t.me/userinfobot) to find it) |
| `allowedChatIds` | Extra chat IDs that may use the bot, separated by commas. To list several, change the field type to *String*. |
| `timezone` | For example `Asia/Kolkata` |
| `defaultStudyTime`, `passScore`, `questionsPerQuiz` | Your preferences |

### 5. Run n8n on your PC with a Cloudflare tunnel (Windows)

Telegram can only deliver messages to a **public HTTPS** address. `http://localhost:5678` only works on your own PC, so Telegram can't reach it. A Cloudflare quick tunnel gives your local n8n a free public `https://….trycloudflare.com` address, with no account or domain needed.

```
Telegram ──HTTPS──▶ https://<random>.trycloudflare.com ──tunnel──▶ cloudflared on your PC ──▶ n8n (localhost:5678)
```

#### Requirements

| Tool | Install | Check it |
|---|---|---|
| Node.js 22 LTS (n8n needs 20.19 or newer) | `winget install OpenJS.NodeJS.LTS` | `node -v` |
| n8n | `npm install -g n8n` | `n8n --version` |
| cloudflared | `winget install --id Cloudflare.cloudflared` | `cloudflared --version` |
| Windows PowerShell 5.1 | Comes with Windows | — |

If a winget install shows a Windows admin prompt, click **Yes**. If you cancel it, the install fails with code `1602`. **Open a new PowerShell window after installing**, so the new commands are found.

#### First-time setup (once)

1. Save your bot token as a user environment variable. Then it's available in every new PowerShell window:

   ```powershell
   [Environment]::SetEnvironmentVariable("TELEGRAM_BOT_TOKEN", "<digits>:<secret>", "User")
   ```

   Open a new window and check it. The result should be about 46:

   ```powershell
   $env:TELEGRAM_BOT_TOKEN.Length
   ```

2. Start n8n once on its own to create your owner account:

   ```powershell
   n8n
   ```

   Open <http://localhost:5678>, create the account, then do steps 2–4 above (import the workflow, create credentials, edit Config). Stop n8n with **Ctrl+C**.

#### Starting n8n (every time)

From the repository folder, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-n8n.ps1
```

[`scripts/start-n8n.ps1`](scripts/start-n8n.ps1) does the following:

1. Checks the bot token with Telegram.
2. Stops anything it started on a previous run, and refuses to start if port 5678 is already in use.
3. Starts `cloudflared` in the background over **HTTP/2**. Many networks block QUIC (UDP), and over QUIC the tunnel can report itself as connected without ever getting a DNS record.
4. Reads the tunnel's real URL from cloudflared's log and waits until it resolves on public DNS. If it doesn't, it retries with a new tunnel, up to 3 times.
5. Starts n8n in a new window with `WEBHOOK_URL` set to the tunnel URL.
6. Checks that n8n is reachable through the tunnel, then asks Telegram which webhook is registered.

A successful run ends like this:

```
OK: n8n is reachable through the tunnel.
OK: Webhook: https://<random>.trycloudflare.com/webhook/<id>/webhook
Editor:  https://<random>.trycloudflare.com
```

#### Opening the n8n editor

- On the same PC: <http://localhost:5678>
- From anywhere else: the `Editor:` URL the script prints. It changes on every start. Some browsers mark `trycloudflare.com` addresses as "Dangerous" because free tunnels are often abused. The warning is about the domain, not your n8n, and Telegram ignores it.

#### Other commands

```powershell
# Only check the Telegram webhook
powershell -ExecutionPolicy Bypass -File .\scripts\start-n8n.ps1 -Check

# Stop the tunnel and n8n
powershell -ExecutionPolicy Bypass -File .\scripts\start-n8n.ps1 -Stop
```

#### Without the script (manual)

1. In PowerShell window 1, start the tunnel and leave it running:

   ```powershell
   cloudflared tunnel --protocol http2 --url http://localhost:5678
   ```

   Copy the `https://….trycloudflare.com` address it prints.

2. In PowerShell window 2, start n8n with that address. Use only the domain and a trailing `/`:

   ```powershell
   $env:WEBHOOK_URL = "https://<random>.trycloudflare.com/"; n8n
   ```

3. Publish (or unpublish and publish again) the workflow, so the Telegram Trigger registers the new address.

4. Check the result:

   ```powershell
   (Invoke-RestMethod "https://api.telegram.org/bot$($env:TELEGRAM_BOT_TOKEN)/getWebhookInfo").result
   ```

   `url` should be `https://<random>.trycloudflare.com/webhook/<id>/webhook`.

Don't call `setWebhook` by hand. The Telegram Trigger node manages the webhook itself.

#### Things to know

- **The URL changes on every tunnel restart.** Always start with the script, or repeat the manual steps. If you start n8n with plain `n8n`, it doesn't know the tunnel URL and the webhook breaks.
- **The bot only works while your PC, the tunnel and n8n are running.** Messages sent while it's off wait on Telegram's side for up to 24 hours.
- **For a URL that never changes,** claim the free static domain in your [ngrok](https://ngrok.com) dashboard, then run:

  ```powershell
  winget install ngrok.ngrok
  ngrok config add-authtoken <your-ngrok-authtoken>
  [Environment]::SetEnvironmentVariable("N8N_NGROK_DOMAIN", "your-name.ngrok-free.app", "User")
  ```

  The script uses that domain automatically from then on. You can also pass it once with `-NgrokDomain your-name.ngrok-free.app`.
- **To run 24/7,** host n8n on a server or n8n Cloud and set `WEBHOOK_URL` to its domain. You don't need a tunnel then.

### 6. Publish

In n8n, open the workflow and click **Publish**, then send `/start` to your bot. If the script reported "No webhook registered", check again after publishing:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-n8n.ps1 -Check
```

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `getWebhookInfo` returns **404** | The bot token is empty or incomplete. It must be `<digits>:<secret>`. In PowerShell, use `$env:TELEGRAM_BOT_TOKEN`. |
| `An HTTPS URL must be provided for webhook` | `WEBHOOK_URL` is `localhost`. Use a tunnel or a public domain. |
| `Failed to resolve host` when publishing | The tunnel's hostname doesn't exist (yet). Use the start script, which waits for DNS. |
| `Wrong response from the webhook: 530` | The tunnel is down. Restart it with the start script. |
| `The database (default) does not exist for project …` | Create a Firestore database in **Native mode** with the ID `(default)`, or set the matching **Database** field in every Firestore node. |
| `Permission denied on resource project …` | The service account is missing the *Cloud Datastore User* role, or `firebaseProjectId` is wrong. |

## Security

- Credentials stay in n8n and are **not** part of the exported workflow.
- Don't commit `.env` files, service-account JSON keys or bot tokens. The included [`.gitignore`](.gitignore) excludes them.
- If a token ever ends up in a commit, revoke it: `/revoke` in BotFather, or delete the key in Google Cloud.
