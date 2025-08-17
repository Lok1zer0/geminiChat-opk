# geminiChat-opk
Auto chat IA for Openkore Ragnarok Online

# requirements
1 - install strawberry perl 5.40 or superior

1.1 - run "cpan LWP::UserAgent JSON HTTP::Request::Common" on CMD and wait finish

2 - move geminiChat folder with geminiChat.pl to your openkore plugin folder

3 - load plugin via macros.txt:
automacro loadGeminiChat {
    priority -1
    run-once 1
    call {
        do plugin load geminiChat
    }
}

4 - get a API key on https://aistudio.google.com/app/apikey

5 - insert this on your config.txt:
gemini_enabled 1
gemini_api_key YOUR_GEMINI_API_KEY
gemini_delay 5
gemini_max_length 100
gemini_model gemini-1.5-flash
gemini_probability 100
gemini_ignore_players

6 - insert your Gemini API key on config.txt and line 59(geminiChat.pl)


# features
Respond to public and private messages in a casual and Brazilian way

BONUS: when approached by GMs switches to "ai manual" and follows him just answering whatever he asks
