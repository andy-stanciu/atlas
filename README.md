# Atlas

A local-first voice assistant for the home. Atlas listens for a wake greeting, holds spoken conversations, recognizes who's talking, and controls the house through a companion tool server — all on your own hardware, with no cloud services involved.

## What it does

- **Spoken conversation** — Say "Hey Atlas" to start talking; replies are streamed and spoken sentence by sentence, and you can interrupt at any time. End things naturally with a closing phrase addressed to Atlas ("thanks Atlas", "that's all Atlas", "goodnight Atlas").
- **Smart-home control** — Room-based lighting today, behind a registry-driven tool layer where new capabilities are declared as data rather than code.
- **Reminders, sequences, and announcements** — Spoken reminders repeat until you acknowledge them aloud; sequences run ordered lists of scheduled actions; announcements are delivered verbatim.
- **Speaker recognition** — Atlas builds voice profiles automatically. An unknown voice is enrolled anonymously on first contact, profiles improve with every confident match, and Atlas occasionally asks an anonymous user for their name — declining is fine, and it will ask again later. Recognized users are greeted and addressed by name.
- **Fully local** — On-device speech recognition (WhisperKit on CoreML), a local LLM (Ollama), and local neural speech synthesis (Kokoro).

## Architecture

Two components talk over HTTP on localhost:

**Client (Swift, macOS)** — the voice frontend. Microphone capture with streaming transcription, turn management, a conversation engine with multi-step tool calling, speaker-identification client, reminder and announcement delivery, and audio playback.

**Tool server (Python)** — the system of record. Tool registry and execution, reminder and sequence scheduling, a speech queue for spoken delivery, the speaker-identification service (voice embeddings and profile storage), and persistence.

```
microphone → streaming STT → conversation engine → LLM → TTS → speaker
                                  │    ▲
                                  ▼    │
                              tool server
                    tools · scheduling · speaker ID
```

## A turn, end to end

1. A wake greeting opens a conversation; follow-up utterances don't need it until the conversation ends.
2. Each utterance is transcribed, and its audio is matched against known speaker profiles.
3. The transcript — with speaker context when the voice is known — goes to the LLM, which calls tools as needed and streams a reply that is spoken as it arrives.
4. Confident matches reinforce the speaker's voice profile; unknown voices are enrolled anonymously without interrupting the conversation.
5. A closing phrase addressed to Atlas ends the conversation, implicitly acknowledging any active reminder on the way out.

## Running locally

Prerequisites: macOS with a Swift toolchain, Ollama, uv, and WhisperKit CoreML models.

1. Start Ollama and pull the configured chat model.
2. Start the tool server via uv.
3. Launch the speech-recognition daemon, then the client.

Endpoints, model names, audio thresholds, and speaker-recognition tuning live in the client and server configuration. See the per-component READMEs for details.

## Repository layout

- `src/client` — Swift package: the assistant, the streaming speech-recognition daemon, and the speech-synthesis worker
- `src/tool-server` — Python service: tools, scheduling, and speaker identification
