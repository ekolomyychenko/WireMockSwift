# Архитектура WireMockSwift

Документ описывает внутреннее устройство библиотеки: слои, поток данных, границы
ответственности, модель конкурентности и то, как всё это расширять. Для пользовательской
документации см. `README.md`.

## Ключевая идея

WireMockSwift — это **клиент**, а не реализация сервера. Он управляет **настоящим Java-сервером
WireMock** (jar/Docker) через его REST Admin API (`/__admin/**`). Всё «тяжёлое» — сопоставление
запросов, Handlebars-шаблоны, семантическое сравнение JSON — выполняет проверенный Java-движок.
Задача библиотеки — дать удобный типобезопасный Swift-DSL и генерировать **байт-точный JSON**,
который сервер принимает.

Из этого следует главный инвариант: *сгенерированный JSON должен совпадать с контрактом сервера*.
Он защищён golden-тестами (см. «Тестирование»).

## Слои

```
┌──────────────────────────────────────────────────────────────┐
│  Пользовательский код (тесты)                                  │
└───────────────┬──────────────────────────────────────────────┘
                │ get(urlEqualTo("/x")).willReturn(ok())
                ▼
┌──────────────────────────────────────────────────────────────┐
│  DSL / билдеры        Sources/WireMock/DSL/*                   │
│  UrlPattern, MappingBuilder, ResponseDefinitionBuilder,        │
│  RequestPatternBuilder, Matchers (free-функции)                │
└───────────────┬──────────────────────────────────────────────┘
                │ .build() → значение-модель
                ▼
┌──────────────────────────────────────────────────────────────┐
│  Модели (Codable)     Sources/WireMock/Models/*               │
│  StubMapping, RequestPattern, ResponseDefinition,             │
│  StringValuePattern, JSONValue, DelayDistribution, Fault, …    │
│  → кодируются в точный JSON контракта WireMock                 │
└───────────────┬──────────────────────────────────────────────┘
                │ Encodable → Data
                ▼
┌──────────────────────────────────────────────────────────────┐
│  Фасад  WireMock      Sources/WireMock/WireMock*.swift        │
│  stubFor / verify / reset / scenarios / recording / …          │
└───────────────┬──────────────────────────────────────────────┘
                │ вызывает
                ▼
┌──────────────────────────────────────────────────────────────┐
│  Admin-транспорт  AdminClient   Sources/WireMock/Admin/*      │
│  синхронно поверх URLSession; сборка URL, статус-коды,        │
│  типизированные ошибки (WireMockError)                        │
└───────────────┬──────────────────────────────────────────────┘
                │ HTTP → /__admin/**
                ▼
        ┌───────────────────────┐
        │  Java-сервер WireMock  │
        │  (jar / Docker)        │
        └───────────────────────┘
```

### Модели (`Sources/WireMock/Models/`)
Value-типы на `Codable`, каждый — зеркало соответствующей JSON-структуры WireMock. Ключевые:
- `StubMapping` — целый маппинг (`request` + `response` + scenario/priority/metadata).
- `RequestPattern` — критерии запроса; `ResponseDefinition` — что вернуть.
- `StringValuePattern` — «матчер» (`{"equalTo": …}` и т.п.); хранит плоский словарь полей и
  кодирует его инлайном. Точка расширения — публичный `init([String: JSONValue])` (сырой люк).
- `JSONValue` — типобезопасный произвольный JSON (для `jsonBody`, `equalToJson`, `metadata`).
  Числа сравниваются/хешируются по величине (`1` == `1.0`), чтобы round-trip через провод не давал
  ложных расхождений.
- `HTTPMethod` — `RawRepresentable`-структура (открыта для кастомных методов), не enum.

Инвариант кодирования: незаданные optional-поля **опускаются** (не пишутся как `null`).

### DSL (`Sources/WireMock/DSL/`)
Fluent-билдеры значений (copy-on-chain, `Sendable`), зеркалящие Java-DSL:
- `MappingBuilder` (`get(...).withHeader(...).willReturn(...)`), `ResponseDefinitionBuilder`,
  `RequestPatternBuilder` (для верификации), `UrlPattern`, `CountMatchingStrategy`.
- Матчеры доступны и как статические фабрики (`StringValuePattern.equalTo`), и как free-функции
  (`equalTo`) — последние зеркалят Java-вызовы.

### Фасад (`WireMock.swift`, `WireMock+Admin.swift`)
Единая точка входа: `stubFor`, `register`, `verify`, `findAll`, `getAllServeEvents`, `reset*`,
scenarios, settings, recording, files, metadata, near-misses. Методы транслируют DSL-значения в
вызовы `AdminClient`.

### Admin-транспорт (`Admin/AdminClient.swift`)
Низкоуровневый **синхронный** клиент поверх `URLSession`: собирает `/__admin/<path>`, кодирует тело,
проверяет статус, отдаёт типизированные `WireMockError`. Транспорт блокирует вызывающий поток на
`DispatchSemaphore`, пока `URLSession.dataTask` не завершится на своей очереди (безопасно с главного
потока — без дедлока). Методы `send`/`get`/`sendData` — `internal` (наружу не торчат).

## Поток данных (пример стаба)

```
get(urlEqualTo("/x")).willReturn(ok("hi"))
        │  MappingBuilder мутирует StubMapping (value type)
        ▼
StubMapping{ request: {method:"GET", url:"/x"}, response: {status:200, body:"hi"} }
        │  JSONEncoder (encodeIfPresent → nil опускаются)
        ▼
POST /__admin/mappings  { … точный JSON контракта … }
        │  AdminClient → URLSession
        ▼
Java-сервер регистрирует стаб; ответ декодируется обратно в StubMapping
```

## Границы ответственности

| | Клиент (эта либа) | Сервер (Java) |
|---|---|---|
| DSL, типобезопасность, кодирование JSON | ✅ | — |
| Admin API, верификация, управление жизненным циклом | ✅ | — |
| Матчинг запросов, Handlebars-шаблоны, `equalToJson`-семантика | — | ✅ |
| Fault injection, прокси, запись трафика | — | ✅ (клиент только конфигурирует) |

Кастомные матчеры/трансформеры как JVM-код исполняются **внутри сервера** — их из клиента задать
нельзя (можно лишь сослаться на уже установленное серверное расширение по имени).

## Escape hatch

Для всего немоделированного (расширения, будущие фичи сервера) есть сырой люк, чтобы не блокировать
пользователя:
- `WireMock.register(json:)` / `register(raw:)` — зарегистрировать маппинг сырым JSON.
- `StringValuePattern([...])` — собрать произвольный матчер из сырых полей.

## Конкурентность

- Основной API — **синхронный** (как Java WireMock): каждый метод блокирует вызывающий поток.
  `WireMock` и `AdminClient` — `Sendable` value-типы **без изменяемого состояния** (всё состояние —
  на сервере), их можно свободно копировать между задачами.
- Опциональный async-мост `wireMock.callAsync { try $0.stubFor(…) }` (`Sources/WireMock/Async.swift`) —
  уводит блокирующий вызов на фоновую очередь через `withCheckedThrowingContinuation`, поэтому **не**
  блокирует cooperative-поток Swift concurrency. Прямой синхронный вызов из async-контекста заблокировал
  бы cooperative-поток — из async используйте `callAsync`; в обычных синхронных тестах он не нужен.
- Сборка чистая под `-strict-concurrency=complete` (язык-режим Swift 6).

## Платформенные границы

- **Клиент** (`WireMock`, DSL, верификация) работает на всех Apple-платформах и Linux — только
  Foundation/`URLSession`.
- Сервер поднимается **снаружи** (на хосте/CI), а клиент указывает на него по адресу.
- Для XCUITest сервер (jar или Docker) поднимается на Mac-хосте; приложение и тест-раннер в
  симуляторе ходят на `localhost` (симулятор форвардит его на хост).

## Конфигурация: порт не хардкодится

Адрес сервера всегда параметризуется — нигде не зашит жёстко на `8080`:
- `WireMock(host:port:)`, `WireMock(scheme:host:port:)`, `WireMock(baseURL:)` — любой порт/хост.
- Тесты и примеры читают адрес из `WIREMOCK_URL` (для XCUITest его можно задать, например, через
  `.xctestplan`; при отсутствии — дефолт `http://localhost:8080`), что позволяет запускать несколько
  инстансов WireMock на разных портах (например, для параллельных сьютов).

## Как расширять

- **Новый матчер:** добавить фабрику в `StringValuePattern`(+`+Advanced.swift`) и, для симметрии,
  free-функцию в `Matchers.swift`. Ключ JSON должен совпадать с контрактом сервера.
- **Новый admin-эндпоинт:** добавить метод на фасад (`WireMock+Admin.swift`), вызывающий
  `admin.send/get`. При новом формате ответа — модель + envelope-DTO (`internal`).
- **Новая опция ответа/запроса:** поле в `ResponseDefinition`/`RequestPattern` + метод билдера.

## Тестирование

Две взаимодополняющие сетки:
- **Golden-JSON (юнит):** каждый билдер сериализуется и сверяется с эталонным `JSONValue`
  (семантическое сравнение — порядок ключей не важен). Ловит расхождения контракта без сервера.
- **Интеграционные (live):** против настоящего WireMock — регистрируют стабы, шлют реальные HTTP,
  верифицируют журнал, сбрасывают состояние. Аккуратно скипаются, если сервер недоступен
  (или падают в CI при `WIREMOCK_REQUIRED=1`).

Отдельно `Examples/WireMockXCUIDemo` — доказательство, что либа работает из XCUITest на симуляторе.

## Обработка ошибок

- `WireMockError`: `.unexpectedStatus(code:body:)`, `.transport`, `.decodingFailed`,
  `.invalidBaseURL`. Таймаут транспорта (safety-wait чуть больше request timeout) отменяет задачу и
  бросается как `.transport`.
- `VerificationError(expected:actual:)` — при несовпадении числа запросов в `verify`.
