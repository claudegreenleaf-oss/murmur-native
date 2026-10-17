# How engines assemble a formatting request

Both engines build the chat request the same way so the a6000 server and the local engine behave
identically, and so the static part is a stable prefix for the LLM's prefix cache.

## System message

```
<format-system.txt, verbatim>

<editing_strength fragment>
<writing_style fragment for the style category of this app>
<app_type fragment, omitted when empty>
```

The style category comes from `style_category_for_app_type[context.app.type]`, then
`init.preferences.style.general_style[category]`.

Then the context block, each section omitted when empty, in this exact order:

```
USER NAME: <first> <last>
VOCABULARY: <starred then dictionary terms, comma separated, max 200>
APP: <app.name> (<app.bundle_id>)<, url when present>
WINDOW: <window_title>
TEXT BEFORE CURSOR:
<<<
<textbox.before_text, last 500 chars>
>>>
SELECTED TEXT:
<<<
<textbox.selected_text>
>>>
TEXT AFTER CURSOR:
<<<
<textbox.after_text, first 500 chars>
>>>
SCREEN WORDS: <screen_ax + variable_names + file_names + screen_ocr, de-duplicated, max 150, comma separated>
```

Prefix warm-up: at `init` (and again on a `context` update), the engine sends the system message
alone with `max_tokens: 1` so the prefill happens while the user is still speaking. The final
request then only prefills the user message.

## User message

```
TRANSCRIPT:
<<<
<raw transcript after replacement rules>
>>>
```

## Decoding

Temperature 0, no reasoning/thinking (Qwen: `chat_template_kwargs: {"enable_thinking": false}`),
`max_tokens` = 2 x transcript tokens + 64, stop on nothing special. Timeout 4 s, then fall back to
rule-based cleanup (`format_skip_reason = "formatter_timeout"`).

## Post-processing on the engine (in this order)

1. Strip wrapping quotes, "TRANSCRIPT:" echoes, and `<<<`/`>>>` echoes if the model emitted them.
2. Hallucination guard: if the output is longer than 1.6x the transcript plus 20 words, or its
   word-level overlap with the transcript is below 0.5 (for verbatim and light strength) or 0.3
   (medium and heavy), or it reads as an answer (starts with "Sure", "Here is", "Certainly", "As an AI",
   "I can't", or answers a question the transcript asked), use the rule-based cleanup instead and
   set `format_skip_reason = "formatter_hallucination"`.
3. Snippets: if the whole utterance (lowercased, punctuation stripped) equals a trigger, the output
   is exactly the expansion. Otherwise replace each trigger occurrence (case-insensitive, word
   boundaries, tolerant of trailing punctuation) with its expansion.
4. Format mode: `casual_messaging` lowercases the first letter of each sentence unless the word is a
   proper noun (vocabulary, user name, screen words, or capitalized mid-sentence in the transcript);
   `all_lowercase` lowercases everything.
5. HTML: `1. ` runs become `<ol><li>`, `- ` runs become `<ul><li>`, blank-line paragraphs become
   `<p>`, single newlines `<br>`. Text is HTML-escaped. `plaintext` keeps the markers.
6. `starts_with_proper_noun`: true when the first word is in the vocabulary, the user's name, the
   screen words, or is "I".
