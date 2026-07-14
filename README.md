# WireMockSwift

Нативный Swift-клиент и DSL для [WireMock](https://wiremock.org), который близко повторяет Java DSL
и Admin API.

Это **не** повторная реализация сервера — библиотека управляет настоящим сервером WireMock (запущенным
через Docker или standalone-jar) через его REST API `/__admin/**`. Всё сопоставление
запросов, шаблонизация ответов и сравнение JSON выполняются проверенным Java-движком, поэтому поведение
идентично Java WireMock; этот пакет даёт вам выразительный, типобезопасный способ настраивать и
верифицировать его на Swift.

- ✅ Полный набор матчеров запросов, все опции ответов, сбои и задержки, сценарии, проксирование,
  запись/воспроизведение, верификация, near-misses, настройки, файлы, метаданные и вебхуки
- ✅ Покрывает всю задокументированную поверхность Admin API `/__admin`
- ✅ Синхронный API (как Java WireMock) + `callAsync` для `async`-контекста; `Sendable` под строгой конкурентностью Swift 6; macOS + Linux + iOS
- ✅ Тестовые наборы golden-JSON + live-server; запасной выход через сырой JSON для всего немоделированного

> **Статус:** ранняя разработка (0.x), первый релиз — `0.1.0`. API ещё может меняться.
> Лицензия — Apache-2.0. Проверено на WireMock **3.13.2**.

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
- [Ошибки и конкурентность](#ошибки-и-конкурентность)
- [Использование в тестах](#использование-в-тестах)
- [Непрерывная интеграция](#непрерывная-интеграция)
- [Особенности платформ](#особенности-платформ)
- [Паритет с Java WireMock](#паритет-с-java-wiremock)
- [Тестирование этого пакета](#тестирование-этого-пакета)
- [Лицензия](#лицензия)

## Требования

- Swift 6.0+ (собирается чисто под `-strict-concurrency=complete`)
- Запущенный сервер WireMock **3.x** (образ Docker или standalone-jar)
- Платформы: macOS 12+, iOS 15+, tvOS 15+, watchOS 8+ и Linux.

## Установка

Swift Package Manager — добавьте в `Package.swift`:

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

let wireMock = WireMock(baseURL: URL(string: "http://localhost:8080")!)

try wireMock.stubFor(
    get(urlEqualTo("/hello"))
        .willReturn(okForJson(["message": "world"]))
)

// ... ваш тестируемый код обращается к http://localhost:8080/hello ...

try wireMock.verify(getRequestedFor(urlEqualTo("/hello")))

try wireMock.resetAll()   // чистое состояние между тестами
```

## Запуск сервера WireMock

Есть два варианта; выбирайте по вашему окружению и месту запуска тестов.

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
try wireMock.stubFor(
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
> смещение/усечение datetime, XPath-подматчеры) живут только на статических фабриках
> `StringValuePattern.`.

> **Числовые матчеры** (`equalToNumber`/`greaterThan`/`lessThan`/…) — это фича **WireMock 4.0+**;
> сервер 3.13.2 отклоняет их с HTTP 422, поэтому в DSL их нет. На 3.x сопоставляйте числа через
> JSONPath-предикат: `matchingJsonPath("$[?(@.age > 5)]")`.

## Ответы

```swift
ok()                                  // 200
ok("plain body")
okForJson(["id": 1])                  // 200 + application/json
okForContentType("text/csv", "a,b,c") // 200 + заданный Content-Type
jsonResponse(["error": "nope"], status: 422)
created(); noContent(); badRequest(); notFound(); serverError()   // и другие
temporaryRedirect(to: "/new"); permanentRedirect(to: "/new"); seeOther(to: "/other")
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
try wireMock.verify(postRequestedFor(urlEqualTo("/things")))

// Точные / относительные счётчики — бросает VerificationError, если не выполнено:
try wireMock.verify(.exactly(3), getRequestedFor(urlEqualTo("/ping")))
try wireMock.verify(.moreThanOrExactly(1), getRequestedFor(urlEqualTo("/ping")))
try wireMock.verify(.lessThan(5), getRequestedFor(urlEqualTo("/ping")))

// Запросы к журналу:
let count   = try wireMock.count(getRequestedFor(urlEqualTo("/ping")))
let matched = try wireMock.findAll(postRequestedFor(urlEqualTo("/things")))
let events  = try wireMock.getAllServeEvents()
let unmatched = try wireMock.getUnmatchedRequests()
let nearMisses = try wireMock.findNearMissesForAllUnmatched()

try wireMock.resetRequests()                                   // очистить журнал
try wireMock.removeServeEvents(matching: getRequestedFor(urlEqualTo("/ping")))
```

`RequestPatternBuilder` поддерживает те же критерии, что и создание стабов (`withHeader`, `withoutHeader`,
`withQueryParam`, `withCookie`, `withRequestBody`, `withBasicAuth` и т. д.).

## Сценарии (управление состоянием)

```swift
try wireMock.stubFor(
    get(urlEqualTo("/next")).inScenario("flow")
        .whenScenarioStateIs("Started").willSetStateTo("step-2")
        .willReturn(ok("first"))
)
try wireMock.stubFor(
    get(urlEqualTo("/next")).inScenario("flow")
        .whenScenarioStateIs("step-2").willReturn(ok("second"))
)

let scenarios = try wireMock.getAllScenarios()
try wireMock.setScenarioState(name: "flow", state: "step-2")
try wireMock.resetScenario(name: "flow")     // один сценарий
try wireMock.resetAllScenarios()             // все
```

## Проксирование, сбои и задержки

```swift
// Проксировать несовпавший/выбранный трафик на реальный бэкенд:
try wireMock.stubFor(
    any(urlPathMatching("/api/.*")).willReturn(
        aResponse().proxiedFrom("https://api.example.com")
            .withProxyUrlPrefixToRemove("/api")
            .withAdditionalRequestHeader("X-From", "wiremock")
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
try wireMock.setGlobalFixedDelay(200)
```

## Запись, файлы, метаданные и настройки

```swift
try wireMock.startRecording(targetBaseUrl: "https://api.example.com")
// ... прогоните трафик через прокси ...
let generated = try wireMock.stopRecording()   // [StubMapping]
let status = try wireMock.getRecordingStatus()
let snapshot = try wireMock.takeSnapshot()
// ⚠️ `targetBaseUrl` должен указывать на ОТДЕЛЬНЫЙ апстрим — направив его обратно на
//    тот же экземпляр WireMock, вы создадите петлю самопроксирования, которая зависает.

// __files:
try wireMock.putFile(named: "body.json", text: #"{"hi":true}"#, contentType: "application/json")
let names = try wireMock.listFiles()
let data = try wireMock.getFile(named: "body.json")
try wireMock.deleteFile(named: "body.json")
// Примечание: WireMock 3.x не выполняет percent-decode сегментов пути, поэтому имена
// сценариев и __files должны быть URL-безопасными — имя с пробелами/`%`/юникодом
// хранится и адресуется в закодированной форме (например, "a b.json" → "a%20b.json").

// Метаданные и массовый импорт:
let stubs = try wireMock.findStubsByMetadata(matchingJsonPath("$.team", equalTo("payments")))
try wireMock.removeStubsByMetadata(matchingJsonPath("$.team", equalTo("payments")))
try wireMock.importMappings([stub1, stub2])

// Настройки:
try wireMock.updateGlobalSettings(GlobalSettings(fixedDelay: 100))
let settings = try wireMock.getGlobalSettings()   // расширенные настройки — в .extended (вложенный ключ `extended`)
let health = try wireMock.getHealth()
```

## Вебхуки

Инициируйте исходящий HTTP-вызов при срабатывании стаба (встроенный слушатель `webhook`):

```swift
try wireMock.stubFor(
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
try wireMock.register(raw: #"""
{ "request": { "method": "GET", "url": "/raw" },
  "response": { "status": 200, "body": "ok" } }
"""#)

try wireMock.register(json: ["request": ["method": "GET", "url": "/x"],
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
(`resetAll()`), а не клиент.

### Защищённая админка и HTTPS

Если админ-API защищён (`--admin-api-basic-auth`), передайте креды:

```swift
let wireMock = WireMock(baseURL: URL(string: "http://ci-host:8080")!,
                        authorization: .basic(username: "admin", password: "s3cret"))
// также: .bearer(token: "…") или .header(value: "…")
// Есть и failable-удобство: WireMock(host:port:) -> WireMock? (nil при кривом host/port).
```

Для HTTPS с самоподписанным сертификатом внедрите свой `URLSession` с делегатом, доверяющим dev-серту
(так безопаснее, чем глобально отключать ATS): `WireMock(baseURL: url, session: mySession)`.

## Использование в тестах

Клиент **синхронный** (как Java WireMock): вызовы блокирующие, что в тестах безвредно — вы всё равно
ждёте каждый шаг последовательно. Никакого `async`/`await` в обычных тестах не нужно. Сбрасывайте
**сервер** через `resetAll()` (а не клиент — всё состояние там).

### Синхронно (основной способ)

```swift
final class CheckoutTests: XCTestCase {
    let wireMock = WireMock(baseURL: URL(string: "http://localhost:8080")!)

    override func setUpWithError() throws { try wireMock.resetAll() }

    func testCheckout() throws {
        try wireMock.stubFor(get(urlEqualTo("/cart")).willReturn(okForJson(["items": 2])))
        // ... прогоните приложение, затем ...
        try wireMock.verify(getRequestedFor(urlEqualTo("/cart")))
    }
}
```

### Из `async`-контекста (опционально)

Если позвать клиент нужно **из `async`-кода**, оберните вызов в `callAsync` — он уводит блокирующую
работу на фоновую очередь и не блокирует Swift-concurrency (cooperative) поток:

```swift
func testCheckout() async throws {
    try await wireMock.callAsync { try $0.stubFor(get(urlEqualTo("/cart")).willReturn(okForJson(["items": 2]))) }
    // ... прогоните приложение, затем ...
    try await wireMock.callAsync { try $0.verify(getRequestedFor(urlEqualTo("/cart"))) }
}
```

> Прямой вызов синхронного метода из `async`-контекста заблокирует cooperative-поток — из `async`
> используйте `callAsync`. В обычных (синхронных) тестах он не нужен.

### Логирование (Allure и т.п.)

Все публичные типы имеют `description` в формате Java WireMock `toString()`: контейнеры
(`StubMapping`, `LoggedRequest`, `ServeEvent`, `RequestPattern`, `ResponseDefinition`, `NearMiss`, …)
печатаются как их JSON, leaf-типы — голым значением (`HTTPMethod` → `GET`, `Fault` → `EMPTY_RESPONSE`).
Так что `"\(stub)"` / `String(describing: loggedRequest)` дают читаемую строку для step-имён и вложений,
а не рефлексивный дамп. Секреты не светятся: `AdminAuthorization`/`WireMock`/`AdminClient` маскируют
креды в своих описаниях.

```swift
Allure.step("Стаб: \(stub)") { … }                 // JSON стаба
XCTContext.runActivity(named: "\(loggedRequest)") { … }
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

> **Сервер — это Java-процесс, который должен работать на хосте** (как jar или через Docker); он не
> может запускаться внутри симулятора/бандла iOS-тестов. Запустите сервер на **хосте** — как jar
> (работает везде, где есть лишь JDK) **или** через Docker, если доступен, — и подключайтесь из
> симулятора.

Подключите продукт `WireMock` к вашему **таргету UI-тестов**. Тест-раннер (на симуляторе) и настраивает
стабы, и управляет приложением; `localhost:8080` внутри симулятора достигает сервера на хосте:

```swift
import XCTest
import WireMock

final class PingUITests: XCTestCase {
    func testAppRendersStubbedResponse() throws {
        let wireMock = WireMock(baseURL: URL(string: "http://localhost:8080")!)
        try wireMock.resetAll()
        try wireMock.stubFor(get(urlEqualTo("/ping")).willReturn(ok("pong")))

        let app = XCUIApplication()
        app.launchEnvironment["WIREMOCK_URL"] = "http://localhost:8080"
        app.launch()

        let label = app.staticTexts["result"]
        XCTAssertTrue(label.waitForExistence(timeout: 10))
        wait(for: [expectation(for: NSPredicate(format: "label == %@", "pong"),
                               evaluatedWith: label)], timeout: 10)
        try wireMock.verify(getRequestedFor(urlEqualTo("/ping")))
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

Готовый к использованию workflow GitHub Actions находится в
[`.github/workflows/ci.yml`](.github/workflows/ci.yml): раннеры macOS со standalone-jar, запущенным на
хосте — юнит + интеграция, сборка под iOS и пример iOS XCUITest (все с воротами готовности).

## Особенности платформ

- **Клиент** (`WireMock`, DSL, верификация) работает на всех платформах Apple и на Linux.
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
  запущенный снаружи сервер (jar/Docker).
- **Типизированная `WireMockConfiguration`** — настройка запуска сервера передаётся как сырые CLI-
  `extraArgs`, а не как типизированный объект опций.
- **Числовые матчеры** доступны с WireMock 4.0+ (паритет с Java, где их также нет на 3.x).

### Известное ограничение: числовая точность в `JSONValue`

`JSONValue` (используется в `jsonBody`, операнде `equalToJson`, `metadata`, параметрах трансформеров)
разбирает числа через `Int`/`Double`. Целые больше `Int64` и дроби с точностью выше ~15–17 значащих
цифр теряют точность (Java/Jackson сохраняют их как `BigInteger`/`BigDecimal`). На практике это редко
встречается в mock-телах. Точность-сохраняющий `Decimal`-вариант пробовался и откачен: на старой Darwin
Foundation `JSONDecoder.decode(Decimal.self)` аварийно завершает процесс вместо чистой ошибки. Если
нужна точная передача большого числа — задавайте его через строковый эскейп-хатч `register(raw:)`.

## Тестирование этого пакета

```bash
swift test                                          # golden-JSON модульные тесты выполняются всегда

java -jar wiremock.jar --port 8080 --disable-banner & # запустить сервер (или docker, если доступен)…
swift test                                          # …теперь выполняются и интеграционные тесты
```

Интеграционные тесты автоматически пропускаются, когда сервер недоступен (переопределите таргет через
`WIREMOCK_URL=http://host:port`).

## Лицензия

Apache-2.0 — см. файлы [`LICENSE`](LICENSE) и [`NOTICE`](NOTICE).
