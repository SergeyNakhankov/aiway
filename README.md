# aiway

Один скрипт — и все AI-сервисы работают. Без VPN.

Разворачивает на вашем VPS прозрачный SNI-прокси ([Angie](https://angie.software/)) + DNS-сервер ([Blocky](https://0xerr0r.github.io/blocky/)), которые направляют трафик к ChatGPT, Claude, Gemini, GitHub Copilot и ещё двадцати с лишним сервисам через ваш сервер — незаметно для приложений.

Основано на методе [crims0n](https://habr.com/ru/articles/982070/) с Хабра.

---

## Как это работает

```
Ваше устройство
    │
    ├─ DNS-запрос openai.com  ──►  Blocky (VPS :53)  ──►  отвечает IP вашего VPS
    │
    └─ TLS на port 443  ──►  Angie (VPS)  ──►  читает SNI, проксирует на настоящий сервер
                                                        (трафик не расшифровывается)
```

- **SNI-прокси** — Angie пересылает TCP-поток на основании имени в TLS ClientHello. Ключи шифрования не нужны, контент не виден.
- **DNS** — Blocky отвечает IP вашего VPS только для AI-доменов; всё остальное резолвится как обычно.
- **Опционально**: DNS-over-TLS (порт 853) и DNS-over-HTTPS при наличии домена с TLS-сертификатом.

---

## Требования

| | |
|---|---|
| **VPS** | Ubuntu 20.04+ или Debian 11+, ~512 МБ RAM |
| **Порты** | 443/tcp, 53/udp+tcp открыты (и 853/tcp для DoT) |
| **На клиенте** | Прописать DNS вашего VPS в настройках сети |

---

## Установка

```bash
git clone https://github.com/yourname/aiway
cd aiway
sudo bash install.sh
```

Скрипт спросит:
1. **IP вашего VPS** (определяется автоматически)
2. **Домен** для DoT/DoH — необязательно, можно пропустить

Всё остальное установится само: Docker, Angie, Blocky, конфиги.

---

## Удаление

```bash
sudo bash uninstall.sh
```

Останавливает и удаляет контейнер Blocky, убирает конфиги Angie, восстанавливает systemd-resolved.

---

## Поддерживаемые сервисы

| Сервис | Домены |
|--------|--------|
| ChatGPT / OpenAI | openai.com, chatgpt.com |
| Claude / Anthropic | claude.ai, anthropic.com |
| Gemini / Google AI | gemini.google.com, aistudio.google.com |
| GitHub Copilot | github.com, githubcopilot.com |
| xAI / Grok | x.ai, grok.com |
| Perplexity | perplexity.ai |
| Midjourney | midjourney.com |
| Hugging Face | huggingface.co |
| Mistral | mistral.ai |
| Cohere | cohere.ai |
| Meta AI | meta.ai |
| Poe | poe.com |
| Character.ai | character.ai |
| You.com | you.com |
| Replicate | replicate.com |
| Stability AI | stability.ai |
| Udio | udio.com |
| Pi | pi.ai |

---

## Добавить новый сервис

Откройте `lib/domains.sh` и добавьте домен в оба массива (`AI_DOMAINS` и `AI_APEX_DOMAINS`), затем перезапустите:

```bash
# На VPS:
angie -t && systemctl reload angie

# Пересоздайте Blocky-конфиг и перезапустите контейнер:
sudo bash install.sh   # повторный запуск обновит конфиги
```

---

## Настройка клиентов

После установки пропишите IP вашего VPS как DNS-сервер:

| Устройство | Где менять |
|-----------|------------|
| **macOS** | Системные настройки → Сеть → Wi-Fi → Подробнее → DNS |
| **iOS / iPadOS** | Настройки → Wi-Fi → (i) → Настроить DNS → Вручную |
| **Android** | Настройки → Wi-Fi → (долгое нажатие) → Изменить → DNS 1 |
| **Windows** | Панель управления → Центр управления сетями → IPv4 → DNS |
| **Роутер** | Обычно: DHCP → DNS 1 (тогда работает для всей сети сразу) |

**С DoT** (если указали домен): в Android 9+ / iOS 14+ можно использовать «Частный DNS» — укажите `ваш-домен`.

---

## Благодарности

Метод описан [crims0n](https://habr.com/ru/articles/982070/) на Хабре — спасибо за детальный разбор.

---

## Лицензия

MIT
