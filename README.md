# Волна

Клиент Яндекс Музыки для iPhone на SwiftUI с Liquid Glass (iOS 26+). В нём только музыка: Моя волна, коллекция и поиск.
Собирается на Windows через [xtool](https://github.com/xtool-org/xtool) в WSL, на телефон ставится через iLoader.

## Что умеет (MVP)

- Вход через Яндекс ID: токен перехватывается из OAuth-редиректа и хранится в Keychain. Есть вариант вставить токен вручную.
- **Моя волна**: бесконечный поток с подгрузкой, лайк и «дальше».
- **Коллекция**: «Мне нравится» с перемешиванием и твои плейлисты.
- **Поиск**: треки, альбомы, плейлисты.
- Плеер:
  - фоновое воспроизведение;
  - экран блокировки, Dynamic Island, AirPods;
  - мини-плеер в стеклянном таббаре;
  - полноэкранный плеер с zoom-переходом;
  - очередь.
- **Караоке:** синхронный текст с заливкой строки, тап по строке перематывает к ней.
- **Моя волна:** учится на прослушиваниях и пропусках (rotor-сессии); настроение, характер и язык задаются в настройках волны; есть волны по занятиям, по треку и по артисту.
- **Меню трека** (долгий тап): играть следующим, в очередь, в плейлист, к артисту или альбому.
- **Страница артиста:** популярное, альбомы, похожие артисты.
- **Плеер:** кроссфейд 0–12 с, бесшовные переходы за счёт предзагрузки следующего трека, таймер сна.
- **Качество:** Lossless (FLAC), MP3 320 или AAC.
- **Виджет:** на «Домой» и на экран блокировки, плюс кнопка «Моя волна» для Пункта управления и кнопки действия.
- Только стриминг, без скачивания в файлы. Lossless временно расшифровывается в tmp на время воспроизведения.

Полные треки играют только при подписке Плюс. API неофициальный, Яндекс может его поменять.

## Один раз: окружение

Все команды выполняются в WSL (Ubuntu 24.04; на Kali Swift официально не поддерживается).

```bash
# PowerShell (Windows):
wsl --install -d Ubuntu-24.04
```

Внутри Ubuntu:

```bash
sudo apt update && sudo apt install -y curl libfuse2t64 usbmuxd
# Swift 6.4 через swiftly
curl -O "https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz"
tar zxf "swiftly-$(uname -m).tar.gz" && ./swiftly init --quiet-shell-followup
. ~/.local/share/swiftly/env.sh
swift --version   # должно быть 6.4

# xtool
curl -fL "https://github.com/xtool-org/xtool/releases/latest/download/xtool-$(uname -m).AppImage" -o xtool
chmod +x xtool && sudo mv xtool /usr/local/bin/
```

Скачай **Xcode 27.1** (`.xip`) в браузере: https://developer.apple.com/download/all/?q=Xcode (нужен вход по Apple ID). Положи файл в «Загрузки», затем:

```bash
xtool sdk install /mnt/c/Users/gures/Downloads/Xcode_27.1.xip
swift sdk list   # должен появиться darwin
```

Если `xtool sdk install` попросит иначе, запусти `xtool setup`. Он спросит способ входа (выбери Password) и путь к xip.

## Сборка

Из PowerShell, одной командой (окружение стоит в `Ubuntu-24.04` под root, Kali не трогается):

```bash
wsl -d Ubuntu-24.04 -u root -- bash /mnt/c/Users/gures/Projects/ymusic-ios/build.sh
```

IPA появится в папке `xtool/`. Открой iLoader, выбери **Import IPA** и укажи этот файл. Подпись живёт 7 дней, потом нужно переустановить.

## Структура

| Путь | Что |
|---|---|
| `Sources/Volna/API` | Модели, клиент `api.music.yandex.net`, получение ссылки на стрим |
| `Sources/Volna/Auth` | Keychain, сессия, вход через OAuth |
| `Sources/Volna/Player` | AVPlayer, очередь, Now Playing, пульт |
| `Sources/Volna/Views` | Экраны и компоненты |
