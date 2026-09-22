# Siri

The Siri plugin sends a message to a new conversation in the Siri app through native Accessibility controls. Replies remain in Siri.

## Requirements

- MacTools 1.3.1 or later.
- macOS 27 with the Siri AI app installed and ready to use.
- Accessibility permission for the MacTools installation you are running.

The marketplace explains missing OS/app requirements and disables incompatible installation. Manual packages and activation use the same checks. After making Siri available, choose **Check Again**. Accessibility permission is setup guidance and does not block installation; Siri onboarding must still be complete before a message can be sent.

## Send a message

1. Open Unified Search and enter `ask siri <message>`.
2. Check that **Ask Siri — New Conversation** is selected.
3. Press Return to send.

You can also type `ask`, highlight the Siri action, and press Tab to insert the configured trigger phrase. Tab only completes the phrase; it does not open Siri or send a message. Alternatively, select the Siri action or the panel's **Ask Siri** button to open the composer.

In the composer, Return sends and Shift-Return inserts a newline. IME composition must finish before sending; Shift-Tab retains its native behavior. While sending, the panel shows progress and **Cancel**. A failed or uncertain attempt keeps its explanation visible; opening a fresh composer does not retry it.

## Change the trigger phrase

In **Settings → Siri**, edit **Trigger phrase** and choose **Save**. **Restore Default** restores `ask siri`. Changes persist and replace the previous phrase immediately.

Matching is case-insensitive. Phrases must be nonempty, at most 64 characters, and contain no leading/trailing whitespace, control characters, or conflicting/overlapping aliases. If a later plugin introduces a conflict, the palette blocks the ambiguous action.

The alias and its first separator space are removed; remaining message text is preserved. Messages must be nonempty and at most 4,096 UTF-8 bytes.

## Delivery and cancellation

MacTools opens Siri, prepares a new conversation, fills the composer, and submits once. It preserves existing drafts and stops if the destination, window, or controls cannot be validated. Only one operation runs at a time.

Read-only control discovery may retry for up to 15 seconds, and new-conversation readiness for up to 10 seconds, within the overall action deadline. Creating a conversation, entering text, and submitting are each attempted once.

If delivery cannot be confirmed, check Siri before trying again: the message may already have been sent. Cancellation cannot retract a submitted message and may leave a draft.

## Privacy and implementation

The plugin does not use the clipboard, AppleScript, private Siri frameworks, or guessed URL parameters. It does not persist prompts, conversation titles, replies, or conversation identifiers. Siri retains conversations according to its own settings and may use Apple's online services.

Only new conversations are supported. The action is local to the palette and does not expose Run Links, unattended rules, App Intents, or saved prompt presets. Siri's Accessibility interface is not a documented automation API and requires revalidation after macOS updates.

Control discovery skips the transcript while retaining access to the composer. An empty-selection screen requires readable evidence of an empty selection. Reusing a fresh empty chat with New Chat disabled requires an empty draft/transcript, writable input, and stable destination identity. Unreadable state never permits entering text.
