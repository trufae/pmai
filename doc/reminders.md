# Reminders

Use the **Reminders** tool group to let the assistant list, add, edit, complete,
reopen, or remove reminders. Turn off **Allow the assistant to change
reminders** to expose only listing. The local reminders manager stays editable.
Choose **None**, **Notification**, or **Audible alarm** when setting a due date.
An alarm uses the platform's alert sound or the terminal bell.

| Platform | Where to manage reminders | Alert delivery |
| --- | --- | --- |
| CLI | `/reminders` and `/help reminders` | The running REPL displays notices and sounds the terminal bell for alarms. It catches up on overdue alerts next time it starts. |
| macOS | Settings → Reminders | Give pmai notification permission. The app queues alerts while open, including reminders saved by local CLI or ACP workers. Queued system notifications can arrive after pmai quits. |
| iOS | Settings → native tools → Reminders | Give PocketMai notification permission for device-local alerts. For Apple Reminders, turn on the integration and allow access. |
| Android | Settings → Tools → Reminders | Allow notification permission. Android restores alerts from the saved list after reboot and delivers them without an open chat. **Allow exact alarms** reduces delays from Android's inexact scheduling. |

On iOS, say “in Apple Reminders” to work in the **PocketMai** list in the
Reminders app. That list is created on the first Apple reminder. Changes made
there are visible to the Reminders tool. The account hosting that list handles
its sync, and Apple Reminders controls its alert sound. PocketMai also keeps a
device-local list for reminders you save in PocketMai. Apple platforms queue up
to 48 local alerts at a time and refill the queue while the app is open.

CLI and macOS use the same reminder list under `PMAI_HOME`. An enabled REPL and
the macOS app can each deliver their own alert. In remote chats, the assistant's
tools operate on the connected host's reminders. The `/reminders` command uses
the current REPL's home.

Example CLI session:

```text
/tools enable reminders
/tools set reminders remindersWriteEnabled false
/reminders at 2027-03-15T09:00:00+01:00 Renew passport
/reminders alarm 2027-03-16T07:30:00+01:00 Leave for the station
/reminders
```

The tool APIs accept ISO 8601 timestamps with an explicit UTC offset. Use the
ID returned by the list or add command for edits, completion, and deletion.
