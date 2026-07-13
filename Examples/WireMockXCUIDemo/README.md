# WireMockXCUIDemo

Проверенный пример: **WireMockSwift из XCUITest на iOS-симуляторе**. Тест-раннер (на симуляторе)
конфигурирует стаб через `WireMock`-клиент, приложение под тестом ходит на тот же сервер по
`localhost` (симулятор форвардит его на хост), и мы верифицируем запрос.

`WireMockServer` из iOS-бандла недоступен — сервер (jar **или** Docker) поднимается **на хосте**.
Порт не зашит: тест берёт адрес из `WIREMOCK_URL` (дефолт `http://localhost:8080`).

## Запуск

```bash
# 1. проект (генерируется из project.yml)
brew install xcodegen        # если ещё нет
xcodegen generate

# 2. WireMock на хосте (любой порт)
java -jar wiremock-standalone-3.13.2.jar --port 8080 --disable-banner &
for i in $(seq 1 30); do curl -sf http://localhost:8080/__admin/health && break; sleep 1; done

# 3. XCUITest на симуляторе
xcodebuild test -project WireMockXCUIDemo.xcodeproj -scheme SampleApp \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5'
```

`.xcodeproj` генерируется из `project.yml` (в git не коммитится — запусти `xcodegen generate`).
