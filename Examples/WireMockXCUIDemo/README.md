# WireMockXCUIDemo

**🇷🇺 Русский** · [🇬🇧 English](README.en.md)

Проверенный пример: **WireMockSwift из XCUITest на iOS-симуляторе**. Тест-раннер (на симуляторе)
конфигурирует стаб через `WireMock`-клиент, приложение под тестом ходит на тот же сервер по
`localhost` (симулятор форвардит его на хост), и мы верифицируем запрос.

Сервер (jar **или** Docker) поднимается **на хосте** — внутри iOS-бандла он недоступен.
Порт не зашит: тест берёт адрес из `WIREMOCK_URL` (дефолт `http://localhost:8080`).

## Запуск

```bash
# 1. проект (генерируется из project.yml)
brew install xcodegen        # если ещё нет
xcodegen generate

# 2. WireMock на хосте (любой порт)
java -jar wiremock-standalone-3.13.2.jar --port 8080 --disable-banner &
for i in $(seq 1 30); do curl -sf http://localhost:8080/__admin/health && break; sleep 1; done

# 3. XCUITest на симуляторе (подставь любой установленный симулятор)
xcodebuild test -project WireMockXCUIDemo.xcodeproj -scheme SampleApp \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

> Имя/версию симулятора подставь под то, что установлено у тебя (`xcrun simctl list devices available`).
> В CI устройство не зашивается: джоба `ios-sim-matrix` выбирает несколько реально доступных
> популярных iPhone, и `ios-xcuitest` гоняет пример по каждому (см. `.github/workflows/ci.yml`).
>
> **Важно про green-skip:** если сервер недоступен (или ты случайно указал реальное устройство,
> а не симулятор — там `localhost` не форвардится на хост), тест по умолчанию делает `XCTSkip` и
> прогон выглядит зелёным. Чтобы недоступность **падала**, запусти с `TEST_RUNNER_WIREMOCK_REQUIRED=1`
> (Xcode прокинет его в раннер как `WIREMOCK_REQUIRED=1`) — именно так и делает CI.

`.xcodeproj` генерируется из `project.yml` (в git не коммитится — запусти `xcodegen generate`).
