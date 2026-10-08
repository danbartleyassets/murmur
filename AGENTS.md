# Instructions for the AI agent setting up Murmur

You are probably here because someone (likely Christian) cloned this repo and asked you to
set it up. This file tells you what Murmur is, how to install it on their Mac, and what to
say to them when you're done.

## What Murmur is

A push-to-talk dictation app for macOS, written by Dan Bartley. The user holds a key, talks,
lets go, and their words are pasted wherever the cursor is, in any app on the Mac.
Transcription runs entirely on the Mac (Whisper on the Neural Engine), so no audio or text
leaves the computer. It sits in the menu bar. `README.md` has the technical detail.

Your job is to install it, not to change it. Don't edit the source unless the user asks.

## Setup

Work through these in order. Tell the user briefly what you're doing as you go.

1. **Check the Mac.** It needs Apple Silicon and macOS 26 or newer.
   ```bash
   uname -m        # must be arm64
   sw_vers         # ProductVersion must be 26 or higher
   ```
   If either fails, stop and tell the user that Murmur won't run on this Mac.

2. **Check for a Swift toolchain** (Swift 6.2 or newer):
   ```bash
   swift --version
   ```
   If it's missing or older, ask the user to run `xcode-select --install` and click
   through the installer, or to update Xcode. You can't complete this step for them.
   Wait until they're done.

3. **Build and install.** From the repo root:
   ```bash
   ./scripts/build-app.sh --install
   ```
   The first build takes a few minutes because it fetches and compiles WhisperKit. The
   script copies `Murmur.app` to `/Applications` and opens it.

4. **Permissions (the user has to click these).** The Murmur window opens with a setup
   card. Tell the user to:
   - click **Allow** next to **Microphone** and accept the macOS prompt
   - click **Allow** next to **Accessibility**, then switch **Murmur** on in the System
     Settings list that opens. Accessibility is what lets Murmur hear the shortcut in
     other apps and paste the text.

5. **Model download.** On first launch Murmur downloads its speech model (about 1.4 GB).
   Progress shows in the window. Setup is done when the Home page says
   **"Ready when you are"**.

6. **Suggest these (optional):**
   - **General › Open at login**, so the model stays loaded and dictation is instant.
   - **Vocabulary:** add names and words Whisper might get wrong (people, products,
     suppliers).
   - **Ask AI** needs Apple Intelligence switched on in System Settings. If it isn't,
     the Ask AI page says so. Everything else works without it.

7. **Test it together.** Ask the user to click into any text field, such as Notes,
   double-tap **Shift** and keep holding, say a sentence, then let go. The text should
   appear.

### If something goes wrong

- **The shortcut does nothing, or Accessibility shows "On" but nothing pastes:** in
  System Settings › Privacy & Security › Accessibility, remove Murmur with **−**, add
  `/Applications/Murmur.app` again with **+**, then quit and reopen Murmur.
- **"No microphone connected":** choose an input on the **Dictation** page, or check
  System Settings › Sound › Input.
- **Build errors:** check `swift --version` is 6.2 or newer and that the Mac has a few
  GB of free disk (build cache plus model is about 3 GB).
- **Updating later:** `git pull && ./scripts/build-app.sh --install`

## Onboarding message: send this when setup is done

Once Murmur says "Ready when you are" and the test worked, give the user the message
below. **Keep it this short.** Don't pad it, add sections or repeat the setup steps,
because a longer message won't get read. Adjust it if they changed the shortcut key.

> **Murmur is set up.** It works in any app on this Mac: wherever you can type, you can talk.
>
> - **Dictate:** double-tap **Shift** and keep holding, talk, let go. Your words are pasted.
> - **Hands-free:** triple-tap **Shift**, talk as long as you like, tap **Shift** once to finish.
> - **Cancel:** press **esc** while recording.
> - **Ask AI:** double-tap **Control** and hold, say a request (e.g. "write a reply saying
>   Thursday works"), let go, and the answer is pasted.
> - Say **"new line"** or **"new paragraph"** for line breaks.
>
> It lives in the menu bar (top right). Open it there to change the shortcut keys, add
> words to its vocabulary, or see recent dictations. Everything stays on this Mac.
