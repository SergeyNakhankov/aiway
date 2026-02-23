#!/usr/bin/env bash
# lib/domains.sh — canonical list of AI domains routed through the VPS
#
# To add a new service, append its apex domain (and any subdomains that need
# separate SNI entries) to AI_DOMAINS.  The installer reads this array to
# generate both the Angie SNI map and the Blocky customDNS block.

AI_DOMAINS=(
    # OpenAI / ChatGPT
    "openai.com"
    "*.openai.com"
    "chatgpt.com"
    "*.chatgpt.com"
    "files.oaiusercontent.com"
    "*.oaiusercontent.com"

    # Anthropic / Claude
    "claude.ai"
    "*.claude.ai"
    "anthropic.com"
    "*.anthropic.com"

    # Google AI
    "gemini.google.com"
    "aistudio.google.com"
    "generativelanguage.googleapis.com"

    # GitHub / Copilot
    "github.com"
    "*.github.com"
    "api.github.com"
    "githubcopilot.com"
    "*.githubcopilot.com"
    "copilot.microsoft.com"

    # xAI / Grok
    "grok.com"
    "*.grok.com"
    "x.ai"
    "*.x.ai"

    # Perplexity
    "perplexity.ai"
    "*.perplexity.ai"

    # Midjourney
    "midjourney.com"
    "*.midjourney.com"

    # Hugging Face
    "huggingface.co"
    "*.huggingface.co"

    # Mistral
    "mistral.ai"
    "*.mistral.ai"

    # Cohere
    "cohere.ai"
    "*.cohere.ai"

    # Meta AI
    "meta.ai"
    "*.meta.ai"

    # Poe
    "poe.com"
    "*.poe.com"

    # Character.ai
    "character.ai"
    "*.character.ai"

    # You.com
    "you.com"
    "*.you.com"

    # Replicate
    "replicate.com"
    "*.replicate.com"

    # Stability AI
    "stability.ai"
    "*.stability.ai"

    # Udio
    "udio.com"
    "*.udio.com"

    # Pi (Inflection)
    "pi.ai"
    "*.pi.ai"
)

# Apex-only list used for DNS (Blocky customDNS does not support wildcards
# the same way — it matches subdomains automatically when the apex is listed).
AI_APEX_DOMAINS=(
    "openai.com"
    "chatgpt.com"
    "oaiusercontent.com"
    "claude.ai"
    "anthropic.com"
    "gemini.google.com"
    "aistudio.google.com"
    "generativelanguage.googleapis.com"
    "github.com"
    "api.github.com"
    "githubcopilot.com"
    "copilot.microsoft.com"
    "grok.com"
    "x.ai"
    "perplexity.ai"
    "midjourney.com"
    "huggingface.co"
    "mistral.ai"
    "cohere.ai"
    "meta.ai"
    "poe.com"
    "character.ai"
    "you.com"
    "replicate.com"
    "stability.ai"
    "udio.com"
    "pi.ai"
)
