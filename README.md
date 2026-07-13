# WireMockSwift

Нативный Swift-клиент и DSL для [WireMock](https://wiremock.org), который близко повторяет Java DSL
и Admin API.

Это **не** повторная реализация сервера — библиотека управляет настоящим сервером WireMock (запущенным
через Docker, standalone-jar или порождённым из кода) через его REST API `/__admin/**`. Всё сопоставление
запросов, шаблонизация ответов и сравнение JSON выполняются проверенным Java-движком, поэтому поведение
идентично Java WireMock; этот пакет даёт вам выразительный, типобезопасный способ настраивать и
верифицировать его на Swift.

- ✅ Полный набор матчеров запросов, все опции ответов, сбои и задержки, сценарии, проксирование,
  запись/воспроизведение, верификация, near-misses, настройки, файлы, метаданные и вебхуки
- ✅ Покрывает всю задокументированную поверхность Admin API `/__admin`
- ✅ `async/await`, `Sendable` при строгой конкурентности Swift 6, macOS + Linux + iOS
- ✅ Тестовые наборы golden-JSON + live-server; запасной выход через сырой JSON для всего немоделированного

> **Статус:** ранняя разработка (0.x). API ещё может меняться, и ни один релиз пока не помечен тегом —
> поэтому подключить как версионированную зависимость SwiftPM ещё нельзя. Лицензия — Apache-2.0.
> Проверено на WireMock **3.13.2**.

## Содержание

- [Требования](#требования)
- [Установка](#установка)
- [Быстрый старт](#быстрый-старт)
- [Запуск сервера WireMock](#запуск-сервера-wiremock)
- [Создание стабов](#создание-стабов)
- [Матчеры запросов](#матчеры-запросов)
- [Ответы](#ответы)
- [Верификация](#верификация)
- [Сценарии](#сценарии-управление-состоянием)
- [Проксирование, сбои и задержки](#проксирование-сбои-и-задержки)
- [Запись, файлы, метаданные и настройки](#запись-файлы-метаданные-и-настройки)
- [Вебхуки](#вебхуки)
- [Запасной выход](#запасной-выход)
- [Использование в тестах](#использование-в-тестах)
- [Непрерывная интеграция](#непрерывная-интеграция)
- [Особенности платформ](#особенности-платформ)
- [Паритет с Java WireMock](#паритет-с-java-wiremock)
- [Тестирование этого пакета](#тестирование-этого-пакета)
- [Лицензия](#лицензия)

## Требования

- Swift 6.0+ (собирается чисто под `-strict-concurrency=complete`)
- Запущенный сервер WireMock **3.x** (образ Docker, standalone-jar или порождённый через `WireMockServer`)
- Платформы: macOS 12+, iOS 15+, tvOS 15+, watchOS 8+ и Linux. Запуск процесса через `WireMockServer`
  доступен только на macOS/Linux (см. [Особенности платформ](#особенности-платформ)).

## Установка

Swift Package Manager — добавьте в `Package.swift` (после того как релиз помечен тегом; до этого зависьте
от ветки или ревизии):

```swift
.package(url: "https://github.com/ekolomyychenko/WireMockSwift.git", from: "0.1.0")
```

и добавьте продукт в ваш (тестовый) таргет:

```swift
.testTarget(name: "MyAppTests", dependencies: [.product(name: "WireMock", package: "WireMockSwift")])
```

## Быстрый старт

Запустите сервер — standalone-jar требует лишь JDK и работает где угодно (см.
[ниже](#запуск-сервера-wiremock) все варианты, включая ограниченные/корпоративные машины):

```bash
java -jar wiremock-standalone-3.13.2.jar --port 8080
```

Застабьте ответ, вызовите его и проверьте, что он был вызван:

```swift
import WireMock

let wireMock = WireMock(host: "localhost", port: 8080)

try await wireMock.stubFor(
    get(urlEqualTo("/hello"))
        .willReturn(okForJson(["message": "world"]))
)

// ... ваш тестируемый код обращается к http://localhost:8080/hello ...

try await wireMock.verify(getRequestedFor(urlEqualTo("/hello")))

try await wireMock.resetAll()   // чистое состояние между тестами
```

## Запуск сервера WireMock

Есть три варианта; выбирайте по вашему окружению и месту запуска тестов.

**1. Standalone-jar (рекомендуется, максимально переносимо)** — требует только JDK, без Docker, без
шага установки. Скачайте его один раз с Maven Central и, желательно, **положите в свой репозиторий**,
чтобы сборки были воспроизводимыми офлайн:

```bash
curl -sL -o wiremock.jar \
  https://repo1.maven.org/maven2/org/wiremock/wiremock-standalone/3.13.2/wiremock-standalone-3.13.2.jar
java -jar wiremock.jar --port 8080
```

**2. Docker** — удобно для Linux CI, но **часто заблокирован на закрытых корпоративных машинах** — так
что не делайте его единственным путём:

```bash
docker run --rm -p 8080:8080 wiremock/wiremock:3.13.2
```

**3. Из кода (`WireMockServer`)** — тестовый процесс сам запускает и останавливает сервер, используя
любой из доступных вариантов выше. Только для хост-процессов macOS/Linux (не внутри симулятора/устройства
iOS — см. [Особенности платформ](#особенности-платформ)):

```swift
let server = WireMockServer(port: 8080, launch: .jar(path: "wiremock.jar"))
// или: WireMockServer(port: 8080, launch: .docker(image: "wiremock/wiremock:3.13.2"))
try await server.start()          // запускает процесс, опрашивает admin API, пока он не ответит
defer { server.stop() }

try await server.client.stubFor(get(anyUrl).willReturn(ok()))
```

> **Ограниченные / корпоративные окружения.** Предпочитайте **jar** — ему нужен только JDK (часто уже
> присутствует для Android/JVM-инструментов), и его можно закоммитить в репозиторий, так что ни Docker,
> ни сеть не требуются. Если ваша машина не позволяет ни Docker, ни JDK, запустите WireMock один раз на
> общем/CI-хосте и направьте все клиенты на него по сети через `WireMock(baseURL:)` — сервер не обязан
> быть локальным.

> **Порт не фиксирован.** `8080` в примерах — лишь дефолт. Запускайте WireMock на любом порту
> (`--port <N>`), а клиент нацеливайте через `WireMock(port:)` / `WireMock(baseURL:)` или переменную
> `WIREMOCK_URL`. Ничто не привязано к 8080 — можно поднимать несколько инстансов на разных портах
> (например, для параллельных сьютов).

## Создание стабов

Стабы строятся выразительным DSL со значимыми типами, повторяющим Java `MappingBuilder` из WireMock:

```swift
try await wireMock.stubFor(
    post(urlPathEqualTo("/things"))
        .withHeader("Content-Type", equalTo("application/json"))
        .withQueryParam("verbose", equalTo("true"))
        .withRequestBody(matchingJsonPath("$.name"))
        .atPriority(1)
        .withMetadata(["team": "payments"])
        .willReturn(okForJson(["id": 1]))
)
```

Точки входа есть для каждого метода — `get`, `post`, `put`, `patch`, `delete`, `head`, `options`,
`trace`, `any`, и `request(_:_:)` для всего остального: `request(.patch, urlEqualTo("/x"))`, или, поскольку
`HTTPMethod` является `ExpressibleByStringLiteral`, произвольный глагол в виде строки — `request("REPORT", urlEqualTo("/x"))`.
URL сопоставляются через `urlEqualTo`, `urlMatching` (regex), `urlPathEqualTo`, `urlPathMatching`,
`urlPathTemplate` или `anyUrl`.

Критерии запроса: `withHeader` / `withoutHeader`, `withQueryParam`, `withCookie`, `withPathParam`,
`withFormParam`, `withRequestBody`, `withMultipartRequestBody`, `withBasicAuth(username:password:)`,
`withHost` / `withPort` / `withScheme`.

## Матчеры запросов

Каждый матчер доступен как фабрика `StringValuePattern` (`.equalTo(…)`), так и как свободная
функция (`equalTo(…)`), повторяющая Java DSL:

```swift
equalTo("text")                      // + caseInsensitive: / equalToIgnoreCase(_:)
containing("part")                   // notContaining(_:)
matching("[0-9]+")                   // notMatching(_:) (regex)
absent                               // заголовок/параметр должен отсутствовать
anything                             // совпадает с любым значением
binaryEqualTo("aGk=")                // побайтовое сравнение base64

equalToJson(["a": 1], ignoreArrayOrder: true, ignoreExtraElements: true)
matchingJsonPath("$.name")
matchingJsonPath("$.name", containing("bob"))   // с под-матчером
matchingJsonSchema(["type": "object"], version: .v202012)

equalToXml("<a/>")
StringValuePattern.equalToXml("<a/>", enablePlaceholders: true)   // опции → форма фабрики
matchingXPath("/note/to[text()='Bob']", namespaces: ["ns": "http://x"])

before("2020-01-01T00:00:00Z")                   // after(_:), equalToDateTime(_:)
StringValuePattern.after("2020-01-01T00:00:00Z", expectedOffset: 3, expectedOffsetUnit: "days")  // опции → фабрика

and(containing("a"), notContaining("b"))         // or(...), not(...)
hasExactly(equalTo("1"), equalTo("2"))           // повторяющиеся многозначные параметры
includes(containing("red"))
```

Голый строковый литерал — это сокращение для `.equalTo`, поэтому `withHeader("Accept", "application/json")` и
`withHeader("Accept", equalTo("application/json"))` эквивалентны.

> Свободные функции несут **общие** параметры; **расширенные опции** (XML-плейсхолдеры,
> смещение/усечение datetime, XPath-подматчеры, числовые сравнения) живут только на статических фабриках
> `StringValuePattern.`.

> **Числовые матчеры** (`StringValuePattern.equalToNumber/greaterThan/greaterThanOrEqual/lessThan/
> lessThanOrEqual`) требуют **WireMock 4.0+** — WireMock 3.x отклоняет их с HTTP 422. Они доступны
> только как явные фабрики, никогда как свободные функции. На 3.x сопоставляйте числа через JSONPath-
> предикат: `matchingJsonPath("$[?(@.age > 5)]")`.

## Ответы

```swift
ok()                                  // 200
ok("plain body")
okForJson(["id": 1])                  // 200 + application/json
okForContentType("text/csv", "a,b,c") // 200 + заданный Content-Type
jsonResponse(["error": "nope"], status: 422)
created(); noContent(); badRequest(); notFound(); serverError()   // и другие
temporaryRedirect(to: "/new"); permanentRedirect(to: "/new"); seeOther("/other")
status(418)

aResponse()
    .withStatus(200)
    .withStatusMessage("OK")
    .withHeader("X-Trace", "abc")          // многозначный: .withHeader("Set-Cookie", ["a=1", "b=2"])
    .withJsonBody(["ok": true])            // или withBody / withBase64Body / withBodyFile
    .withTransformers("response-template") // серверная шаблонизация Handlebars
    .withTransformerParameter("name", "Bob")
```

## Верификация

```swift
// Хотя бы раз:
try await wireMock.verify(postRequestedFor(urlEqualTo("/things")))

// Точные / относительные счётчики — бросает VerificationError, если не выполнено:
try await wireMock.verify(.exactly(3), getRequestedFor(urlEqualTo("/ping")))
try await wireMock.verify(.moreThanOrExactly(1), getRequestedFor(urlEqualTo("/ping")))
try await wireMock.verify(.lessThan(5), getRequestedFor(urlEqualTo("/ping")))

// Запросы к журналу:
let count   = try await wireMock.count(getRequestedFor(urlEqualTo("/ping")))
let matched = try await wireMock.findAll(postRequestedFor(urlEqualTo("/things")))
let events  = try await wireMock.getAllServeEvents()
let unmatched = try await wireMock.getUnmatchedRequests()
let nearMisses = try await wireMock.findNearMissesForAllUnmatched()

try await wireMock.resetRequests()                                   // очистить журнал
try await wireMock.removeServeEvents(matching: getRequestedFor(urlEqualTo("/ping")))
```

`RequestPatternBuilder` поддерживает те же критерии, что и создание стабов (`withHeader`, `withoutHeader`,
`withQueryParam`, `withCookie`, `withRequestBody`, `withBasicAuth` и т. д.).

## Сценарии (управление состоянием)

```swift
try await wireMock.stubFor(
    get(urlEqualTo("/next")).inScenario("flow")
        .whenScenarioStateIs("Started").willSetStateTo("step-2")
        .willReturn(ok("first"))
)
try await wireMock.stubFor(
    get(urlEqualTo("/next")).inScenario("flow")
        .whenScenarioStateIs("step-2").willReturn(ok("second"))
)

let scenarios = try await wireMock.getAllScenarios()
try await wireMock.setScenarioState(name: "flow", state: "step-2")
try await wireMock.resetScenario(name: "flow")     // один сценарий
try await wireMock.resetAllScenarios()             // все
```

## Проксирование, сбои и задержки

```swift
// Проксировать несовпавший/выбранный трафик на реальный бэкенд:
try await wireMock.stubFor(
    any(urlPathMatching("/api/.*")).willReturn(
        aResponse().proxiedFrom("https://api.example.com")
            .withProxyUrlPrefixToRemove("/api")
            .withAdditionalProxyRequestHeader("X-From", "wiremock")
    )
)

// Сбои:
aResponse().withFault(.connectionResetByPeer)   // .emptyResponse, .malformedResponseChunk, .randomDataThenClose

// Задержки:
aResponse().withFixedDelay(500)
aResponse().withLogNormalRandomDelay(median: 90, sigma: 0.1)
aResponse().withUniformRandomDelay(lower: 15, upper: 25)
aResponse().withChunkedDribbleDelay(numberOfChunks: 5, totalDuration: 1000)

// Глобально (применяется к каждому ответу):
try await wireMock.setGlobalFixedDelay(200)
```

## Запись, файлы, метаданные и настройки

```swift
try await wireMock.startRecording(targetBaseUrl: "https://api.example.com")
// ... прогоните трафик через прокси ...
let generated = try await wireMock.stopRecording()   // [StubMapping]
let status = try await wireMock.getRecordingStatus()
let snapshot = try await wireMock.takeSnapshot()
// ⚠️ `targetBaseUrl` должен указывать на ОТДЕЛЬНЫЙ апстрим — направив его обратно на
//    тот же экземпляр WireMock, вы создадите петлю самопроксирования, которая зависает.

// __files:
try await wireMock.putFile(named: "body.json", text: #"{"hi":true}"#, contentType: "application/json")
let names = try await wireMock.listFiles()
let data = try await wireMock.getFile(named: "body.json")
try await wireMock.deleteFile(named: "body.json")
// Примечание: WireMock 3.x не выполняет percent-decode сегментов пути, поэтому имена
// сценариев и __files должны быть URL-безопасными — имя с пробелами/`%`/юникодом
// хранится и адресуется в закодированной форме (например, "a b.json" → "a%20b.json").

// Метаданные и массовый импорт:
let stubs = try await wireMock.findStubsByMetadata(matchingJsonPath("$.team", equalTo("payments")))
try await wireMock.removeStubsByMetadata(matchingJsonPath("$.team", equalTo("payments")))
try await wireMock.importMappings([stub1, stub2])

// Настройки:
try await wireMock.updateGlobalSettings(GlobalSettings(fixedDelay: 100))
let settings = try await wireMock.getGlobalSettings()   // без потерь: неизвестные ключи сохраняются в .extended
let health = try await wireMock.getHealth()
```

## Вебхуки

Инициируйте исходящий HTTP-вызов при срабатывании стаба (встроенный слушатель `webhook`):

```swift
try await wireMock.stubFor(
    post(urlEqualTo("/order")).willReturn(ok()).withWebhook(
        WebhookDefinition(
            method: .post,
            url: "https://callback.example.com/hook",
            headers: ["Content-Type": "application/json"],
            body: #"{"event":"order.created"}"#,
            delay: .fixed(milliseconds: 200)
        )
    )
)
```

## Запасной выход

Всё, что ещё не смоделировано типизированным DSL (матчеры-расширения, будущие возможности сервера),
по-прежнему можно зарегистрировать из сырого JSON, так что вы никогда не заблокированы:

```swift
try await wireMock.register(raw: #"""
{ "request": { "method": "GET", "url": "/raw" },
  "response": { "status": 200, "body": "ok" } }
"""#)

try await wireMock.register(json: ["request": ["method": "GET", "url": "/x"],
                                   "response": ["status": 204]])
```

`StringValuePattern([...])` аналогично строит произвольный матчер из сырых полей.

## Ошибки и конкурентность

Каждый вызов бросает типизированный **`WireMockError`** (все `CustomStringConvertible`):

- `.unexpectedStatus(code:body:)` — сервер отклонил запрос (например, HTTP 422 для матчера, доступного
  только в 4.x, на сервере 3.x); тело ответа прилагается.
- `.transport(underlying:)` — отказ соединения, таймаут, DNS и т. д.
- `.decodingFailed(underlying:)` — ответ сервера не удалось декодировать.
- `.invalidBaseURL(_:)` — сконфигурированный URL был некорректным.

Несовпадения счётчиков верификации бросают **`VerificationError(expected:actual:)`**.

`WireMock` — это `Sendable` `struct` со значимой семантикой, не хранящий изменяемого состояния — свободно
копируйте его между задачами. Всё состояние живёт на сервере, поэтому между тестами сбрасывайте **сервер**
(`resetAll()`), а не клиент. (`WireMockServer`, запускающий процесс, является ссылочным типом и
`@unchecked Sendable`; используйте один экземпляр на сервер.)

## Использование в тестах

Клиент в первую очередь `async`. Сбрасывайте состояние в каждом тесте для изоляции:

```swift
final class CheckoutTests: XCTestCase {
    let wireMock = WireMock(host: "localhost", port: 8080)

    override func setUp() async throws { try await wireMock.resetAll() }

    func testCheckout() async throws {
        try await wireMock.stubFor(get(urlEqualTo("/cart")).willReturn(okForJson(["items": 2])))
        // ... прогоните приложение, затем ...
        try await wireMock.verify(getRequestedFor(urlEqualTo("/cart")))
    }
}
```

Внутри синхронного тела теста используйте мост `WireMockSync.run` (блокирует с таймаутом; никогда не
вызывайте его из `async`-контекста):

```swift
let stub = try WireMockSync.run { try await wireMock.stubFor(get(anyUrl).willReturn(ok())) }
```

## Непрерывная интеграция

Сервер — это Java-процесс, поэтому **он всегда запускается на CI-хосте** — никогда внутри симулятора или
устройства iOS (они не могут породить JVM). Ваши тесты только *подключаются* к нему. Куда именно они
подключаются, зависит от таргета:

| | Симулятор iOS | Реальное устройство |
|---|---|---|
| Адрес сервера | `http://localhost:8080` (симулятор пробрасывает localhost на хост) | `http://<host-LAN-IP>:8080` |
| Cleartext HTTP (ATS) | нормально для localhost | нужно исключение ATS или HTTPS |
| Запрос локальной сети | нет | появляется (ломает автономные прогоны) |
| Надёжность | высокая | низкая — **в CI предпочитайте симулятор** |

**Рекомендуемый паттерн (хост запускает сервер, тесты подключаются):**

```bash
# 1. запустить WireMock на CI-хосте и дождаться готовности
java -jar wiremock-standalone-3.13.2.jar --port 8080 --disable-banner &
for i in $(seq 1 60); do curl -sf http://localhost:8080/__admin/health && break; sleep 1; done

# 2. запустить тесты (пример для iOS)
xcodebuild test -scheme MyApp -destination 'platform=iOS Simulator,name=iPhone 15,OS=latest'
```

Передача URL тестируемому приложению:

- **Интеграционные/модульные тесты** (вызовы делает тестовый процесс): читайте `ProcessInfo.environment["WIREMOCK_URL"]`
  (задайте через ваш `.xctestplan`) или используйте по умолчанию `http://localhost:8080`.
- **UI-тесты** (отдельный процесс приложения): `app.launchEnvironment["WIREMOCK_URL"] = "http://localhost:8080"`;
  процесс UI-теста настраивает стабы через клиент `WireMock` на `localhost:8080`.

### XCUITest (проверено на симуляторе)

> **`WireMockServer` нельзя использовать из тестового бандла iOS** (он порождает подпроцесс
> `java`/`docker` и вырезается из сборки на iOS). Запустите сервер на **хосте** — как jar (работает
> везде, где есть лишь JDK) **или** через Docker, если доступен, — и подключайтесь из симулятора.

Подключите продукт `WireMock` к вашему **таргету UI-тестов**. Тест-раннер (на симуляторе) и настраивает
стабы, и управляет приложением; `localhost:8080` внутри симулятора достигает сервера на хосте:

```swift
import XCTest
import WireMock

final class PingUITests: XCTestCase {
    func testAppRendersStubbedResponse() async throws {
        let wireMock = WireMock(baseURL: URL(string: "http://localhost:8080")!)
        try await wireMock.resetAll()
        try await wireMock.stubFor(get(urlEqualTo("/ping")).willReturn(ok("pong")))

        let app = XCUIApplication()
        app.launchEnvironment["WIREMOCK_URL"] = "http://localhost:8080"
        app.launch()

        let label = app.staticTexts["result"]
        XCTAssertTrue(label.waitForExistence(timeout: 10))
        await fulfillment(of: [expectation(for: NSPredicate(format: "label == %@", "pong"),
                                           evaluatedWith: label)], timeout: 10)
        try await wireMock.verify(getRequestedFor(urlEqualTo("/ping")))
    }
}
```

Тестируемое приложение читает `WIREMOCK_URL` из своего окружения и направляет сетевые запросы туда.
Добавьте `NSAppTransportSecurity → NSAllowsLocalNetworking = true` **и** в приложение, **и** в таргет
UI-тестов, чтобы cleartext `http://localhost` был разрешён. Этот точный поток проверен сквозным способом
на симуляторе iOS (см. `Examples/WireMockXCUIDemo`).

Два паттерна, которые демонстрирует собственный тестовый каркас этого пакета (скопируйте их в свою тестовую
настройку — они находятся в `Tests/WireMockTests/TestSupport.swift`, а не встроены в поставляемую
библиотеку):

- **Падать, а не пропускать.** Пусть ваша тестовая настройка учитывает переменную окружения
  `WIREMOCK_REQUIRED=1`, чтобы в CI отсутствующий/нездоровый сервер приводил к падению сборки, а не тихому
  пропуску — шторм из пропусков никогда не должен выглядеть зелёным.
- **Только последовательно.** Если интеграционные наборы делят один сервер и сбрасывают его в `setUp`,
  они не безопасны для параллельного запуска; не включайте `--parallel` без изоляции сервера по каждому
  набору.

Готовый к использованию workflow GitHub Actions (Linux-service-контейнер + macOS jar, с воротами готовности)
находится в [`.github/workflows/ci.yml`](.github/workflows/ci.yml).

## Особенности платформ

- **Клиент** (`WireMock`, DSL, верификация) работает на всех платформах Apple и на Linux.
- **`WireMockServer`** (запуск сервера из кода) компилируется только на macOS/Linux — он порождает
  подпроцесс `java`/`docker`, что невозможно на устройстве или симуляторе iOS/tvOS/watchOS. Там
  запускайте сервер на своей хост/CI-машине и направляйте клиент на него через `WireMock(baseURL:)`.
- Требует Java **или** Docker на хосте, где запущен сервер (сам сервер написан на Java).

## Паритет с Java WireMock

Для линейки WireMock **3.x** клиент находится в функциональном паритете с Java-клиентом DSL + Admin
API: каждый оператор матчера запросов, все возможности `MappingBuilder`/`ResponseDefinitionBuilder`,
все сбои и распределения задержек, полная спецификация записи/воспроизведения, сценарии, верификация,
near-misses, метаданные, настройки и файлы присутствуют, и покрыт полный набор эндпоинтов `/__admin` —
плюс запасные выходы для всего немоделированного.

Единственные возможности, которые **недоступны**, — это те, что структурно невозможны из
внепроцессного HTTP-клиента, и это не дефекты:

- **Пользовательские матчеры/трансформеры, написанные как JVM-код** (`RequestMatcherExtension`,
  пользовательский `ResponseTransformer`) выполняются *внутри* сервера. Вы можете сослаться на
  установленное на сервере расширение по имени и передать параметры, но не можете передать Swift-код
  матчера в Java-движок.
- **Встроенный сервер в процессе** — Java может запускать сервер в том же JVM, что и тест; здесь это
  внешний процесс (`WireMockServer`) или отдельно запущенный контейнер.
- **Типизированная `WireMockConfiguration`** — настройка запуска сервера передаётся как сырые CLI-
  `extraArgs`, а не как типизированный объект опций.
- **Числовые матчеры** доступны с WireMock 4.0+ (паритет с Java, где их также нет на 3.x).

## Тестирование этого пакета

```bash
swift test                                          # golden-JSON модульные тесты выполняются всегда

java -jar wiremock.jar --port 8080 --disable-banner & # запустить сервер (или docker, если доступен)…
swift test                                          # …теперь выполняются и интеграционные тесты
```

Интеграционные тесты автоматически пропускаются, когда сервер недоступен (переопределите таргет через
`WIREMOCK_URL=http://host:port`). Задайте `WIREMOCK_JAR=/path/to/wiremock-standalone.jar`, чтобы запустить
загрузочный тест `WireMockServer`.

## Лицензия

Apache-2.0 — см. файлы [`LICENSE`](LICENSE) и [`NOTICE`](NOTICE).
