# geminiChat-opk
Auto chat by IA for Openkore Ragnarok Online

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

5 - insert your Gemini API key on line 59 and have fun


# features
Respond to public and private messages in a casual and Brazilian way

BONUS: when approached by GMs switches to "ai manual" and follows him for 2 minutes just answering whatever he asks
